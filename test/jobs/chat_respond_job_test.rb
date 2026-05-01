require "test_helper"
require "ostruct"

class ChatRespondJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  AGENT_INSTRUCTIONS_TEMPLATE = Rails.root.join("app/prompts/generator_agent/instructions.txt.erb").read.freeze

  setup do
    @user = create_user(openrouter_api_key: "sk-or-test-fixture-1234567890ab")
    @project = @user.projects.create!(name: "Test Project")
    @chat = GeneratorAgent.create!(project: @project)
    @user_message = @chat.messages.create!(role: :user, content: "Hello")
    @stream_name = @project.to_gid_param
  end

  test "happy path: single chunk persists assistant message with chunk content" do
    stub_complete(chunks: [ "Hello" ]) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    assert_equal "Hello", latest_assistant.content
  end

  test "happy path: multiple chunks accumulate into final content" do
    stub_complete(chunks: [ "Hel", "lo, ", "world" ]) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    assert_equal "Hello, world", latest_assistant.content
  end

  test "one broadcast_replace per non-empty chunk plus one append for assistant creation" do
    stub_complete(chunks: [ "a", "b", "c" ]) do
      perform_enqueued_jobs do
        assert_broadcasts(@stream_name, 4) do
          ChatRespondJob.perform_now(@user_message.id)
        end
      end
    end
  end

  test "empty chunk content does not trigger replace broadcast" do
    stub_complete(chunks: [ "", nil, "real" ]) do
      perform_enqueued_jobs do
        assert_broadcasts(@stream_name, 2) do
          ChatRespondJob.perform_now(@user_message.id)
        end
      end
    end
    assert_equal "real", latest_assistant.content
  end

  test "no chunks: assistant message remains empty, only the creation append broadcast" do
    stub_complete(chunks: []) do
      perform_enqueued_jobs do
        assert_broadcasts(@stream_name, 1) do
          ChatRespondJob.perform_now(@user_message.id)
        end
      end
    end
    assert_equal "", latest_assistant.content
  end

  test "exception mid-stream: broadcasts a chat_notice banner with friendly text" do
    stub_complete(chunks: [ "partial ", "more" ], raise_at: 1) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    notice = last_chat_notice_broadcast
    assert notice, "expected a chat_notice broadcast"
    assert_match(/Something went wrong/, notice)
  end

  test "exception before first chunk: broadcasts a chat_notice (no assistant Message persisted by us)" do
    before = @chat.messages.where(role: :assistant).count
    stub_complete(chunks: [], raise_immediately: true) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    after  = @chat.messages.where(role: :assistant).count
    assert_equal before, after, "rescue must not append an assistant message"
    assert last_chat_notice_broadcast, "expected a chat_notice broadcast"
  end

  test "applies the GeneratorAgent instructions via with_instructions on each perform" do
    captured = []
    spy_with_instructions(captured) do
      stub_complete(chunks: [ "ok" ]) do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end

    assert_equal 1, captured.size
    args, _kwargs = captured.first
    rendered = args.first
    # Rendered instructions = static prompt body + interpolated project state.
    assert_includes rendered, "describe a Rails web application"
    assert_includes rendered, "Current project state:"
    assert_includes rendered, "No generation is currently running"
  end

  test "injects a RUNNING state line when the project has a non-terminal instruction" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    2.times do |i|
      instruction.revisions.create!(
        project: @project, position: i, status: (i.zero? ? :completed : :pending),
        summary: "rev #{i}", prompt: "p"
      )
    end

    captured = []
    spy_with_instructions(captured) do
      stub_complete(chunks: [ "ok" ]) do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end

    rendered = captured.first.first.first
    assert_includes rendered, "CURRENTLY RUNNING"
    assert_includes rendered, "instruction ##{instruction.id}"
    assert_includes rendered, "1/2 revisions complete"
    assert_includes rendered, "Do NOT call `start_generation` now"
  end

  test "registers a StartGeneration tool bound to the project before completing" do
    captured_tools = []
    spy_with_tools(captured_tools) do
      stub_complete(chunks: [ "ok" ]) do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end

    tools = captured_tools.first
    start_gen = tools.find { |t| t.is_a?(StartGeneration) }
    assert start_gen, "expected a StartGeneration tool instance passed to with_tools"
    assert_equal @project, start_gen.instance_variable_get(:@project)
  end

  test "calls with_context carrying the project owner's openrouter key" do
    captured_ctxs = []
    spy_with_context(captured_ctxs) do
      stub_complete(chunks: [ "ok" ]) do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end
    assert_equal 1, captured_ctxs.size
    ctx = captured_ctxs.first
    assert_kind_of RubyLLM::Context, ctx
    assert_equal "sk-or-test-fixture-1234567890ab", ctx.config.openrouter_api_key
  end

  test "broadcasts a friendly chat_notice when project owner has no openrouter key" do
    @user.profile.update_columns(openrouter_api_key: nil)
    perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    assert_match(/Add your OpenRouter API key in Account/, last_chat_notice_broadcast)
  end

  test "with_context preserves acts_as_chat persistence callbacks (assistant message persisted)" do
    # The plan §Phase 4 step 6 paranoia: switching agent.complete →
    # agent.with_context(ctx).complete must not strip the on_new_message /
    # on_end_message callbacks that acts_as_chat installs.
    stub_complete(chunks: [ "callback survived" ]) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    assistants = @chat.messages.where(role: :assistant)
    assert_equal 1, assistants.count
    assert_equal "callback survived", assistants.first.content
  end

  test "scrubs sk-or-* secrets from rescue log lines (banner shows friendly text only)" do
    leaked_key = "sk-or-leaked123456789abcdef"
    io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(io)
    begin
      stub_complete(chunks: [], raise_immediately: true, raise_message: "auth failed for #{leaked_key}") do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    ensure
      Rails.logger = original_logger
    end
    refute_includes io.string, leaked_key, "expected log output to be scrubbed"
    assert_includes io.string, "[FILTERED]"
    notice = last_chat_notice_broadcast
    refute_includes notice.to_s, leaked_key,
      "banner must not echo the raw exception message (and thus the key)"
  end

  test "RubyLLM::BadRequestError: maps to a 'start a new project' banner, not the generic 'something went wrong'" do
    Chat.class_eval do
      alias_method :_complete_for_badreq, :complete if method_defined?(:complete) && !method_defined?(:_complete_for_badreq)
      define_method(:complete) { |**_kwargs, &_b| raise RubyLLM::BadRequestError, "Provider returned error - tool_use_id mismatch" }
    end
    perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }

    notice = last_chat_notice_broadcast
    assert notice, "expected a chat_notice broadcast"
    assert_match(/can't be continued|start a new project/i, notice)
    refute_match(/Something went wrong/, notice)
  ensure
    Chat.class_eval do
      alias_method :complete, :_complete_for_badreq if method_defined?(:_complete_for_badreq)
    end
  end

  test "registers a SuggestPrompts tool bound to the project before completing" do
    captured_tools = []
    spy_with_tools(captured_tools) do
      stub_complete(chunks: [ "ok" ]) do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end

    tools = captured_tools.first
    suggest = tools.find { |t| t.is_a?(SuggestPrompts) }
    assert suggest, "expected a SuggestPrompts tool instance passed to with_tools"
    assert_equal @project, suggest.instance_variable_get(:@project)
  end

  private

  def last_chat_notice_broadcast
    broadcasts(@stream_name).reverse.find { |b| b.to_s.match?(/target=\\?"chat_notice\\?"/) }
  end

  def latest_assistant
    @chat.messages.where(role: :assistant).order(:id).last
  end

  def stub_complete(chunks:, raise_at: nil, raise_immediately: false, raise_message: "boom")
    ChatCompleteStub.chunks = chunks
    ChatCompleteStub.raise_at = raise_at
    ChatCompleteStub.raise_immediately = raise_immediately
    ChatCompleteStub.raise_message = raise_message

    Chat.class_eval do
      alias_method :_original_complete, :complete if method_defined?(:complete) && !method_defined?(:_original_complete)
      define_method(:complete) do |**_kwargs, &block|
        raise StandardError, ChatCompleteStub.raise_message if ChatCompleteStub.raise_immediately
        messages.create!(role: :assistant, content: "")
        ChatCompleteStub.chunks.each_with_index do |content, i|
          raise StandardError, ChatCompleteStub.raise_message if ChatCompleteStub.raise_at == i
          block&.call(OpenStruct.new(content: content))
        end
      end
    end
    yield
  ensure
    Chat.class_eval do
      alias_method :complete, :_original_complete if method_defined?(:_original_complete)
    end
  end

  module ChatCompleteStub
    class << self
      attr_accessor :chunks, :raise_at, :raise_immediately, :raise_message
    end
  end

  def spy_with_context(captured)
    Chat.class_eval do
      alias_method :_original_with_context, :with_context
      define_method(:with_context) do |context|
        captured << context
        _original_with_context(context)
      end
    end
    yield
  ensure
    Chat.class_eval do
      alias_method :with_context, :_original_with_context if method_defined?(:_original_with_context)
    end
  end

  def spy_with_instructions(captured)
    Chat.class_eval do
      alias_method :_original_with_runtime_instructions, :with_runtime_instructions
      define_method(:with_runtime_instructions) do |*args, **kwargs, &block|
        captured << [ args, kwargs ]
        _original_with_runtime_instructions(*args, **kwargs, &block)
      end
    end
    yield
  ensure
    Chat.class_eval do
      alias_method :with_runtime_instructions, :_original_with_runtime_instructions if method_defined?(:_original_with_runtime_instructions)
    end
  end

  def spy_with_tools(captured)
    RubyLLM::Chat.class_eval do
      alias_method :_original_with_tools, :with_tools
      define_method(:with_tools) do |*tools, **kwargs, &block|
        captured << tools
        _original_with_tools(*tools, **kwargs, &block)
      end
    end
    yield
  ensure
    RubyLLM::Chat.class_eval do
      alias_method :with_tools, :_original_with_tools if method_defined?(:_original_with_tools)
    end
  end
end
