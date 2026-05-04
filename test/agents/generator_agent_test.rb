require "test_helper"
require "ostruct"

# Verifies the GeneratorAgent's tool surface is mutually exclusive on
# Project#workspace_initialized?:
# - empty workspace (Gemfile absent)  -> CreateApplication is bound, ModifyApplication is not
# - initialized workspace (Gemfile present) -> ModifyApplication is bound, CreateApplication is not
#
# Captures the tools list by spying on RubyLLM::Chat#with_tools while running
# ChatRespondJob with a stubbed Chat#complete. This is the same pattern used
# in test/jobs/chat_respond_job_test.rb.
class GeneratorAgentTest < ActiveJob::TestCase
  setup do
    @user = create_user(openrouter_api_key: "sk-or-test-fixture-1234567890ab")
    @project = @user.projects.create!(name: "Agent tools test")
    @chat = GeneratorAgent.create!(project: @project)
    @user_message = @chat.messages.create!(role: :user, content: "hi")
  end

  teardown do
    FileUtils.rm_rf(@project.workspace_path) if @project.workspace_path && File.directory?(@project.workspace_path)
  end

  test "binds CreateApplication when workspace is not initialized" do
    refute @project.workspace_initialized?, "test setup expected uninitialized workspace"

    captured = capture_tools_during_complete

    classes = captured.map(&:class)
    assert_includes classes, CreateApplication
    refute_includes classes, ModifyApplication
    assert_includes classes, SuggestPrompts
  end

  test "binds ModifyApplication when workspace is initialized" do
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), "# fake\n")
    assert @project.workspace_initialized?

    captured = capture_tools_during_complete

    classes = captured.map(&:class)
    assert_includes classes, ModifyApplication
    refute_includes classes, CreateApplication
    assert_includes classes, SuggestPrompts
  end

  test "the bound mutation tool is initialized with the chat's project" do
    captured = capture_tools_during_complete
    create_app = captured.find { |t| t.is_a?(CreateApplication) }
    assert_equal @project, create_app.instance_variable_get(:@project)
  end

  private

  def capture_tools_during_complete
    captured_tools_lists = []
    spy_with_tools(captured_tools_lists) do
      stub_complete do
        perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
      end
    end
    captured_tools_lists.first
  end

  def stub_complete
    Chat.class_eval do
      alias_method :_original_complete_for_agent_test, :complete if method_defined?(:complete) && !method_defined?(:_original_complete_for_agent_test)
      define_method(:complete) do |**_kwargs, &_block|
        messages.create!(role: :assistant, content: "")
      end
    end
    yield
  ensure
    Chat.class_eval do
      alias_method :complete, :_original_complete_for_agent_test if method_defined?(:_original_complete_for_agent_test)
    end
  end

  def spy_with_tools(captured)
    RubyLLM::Chat.class_eval do
      alias_method :_original_with_tools_for_agent_test, :with_tools
      define_method(:with_tools) do |*tools, **kwargs, &block|
        captured << tools
        _original_with_tools_for_agent_test(*tools, **kwargs, &block)
      end
    end
    yield
  ensure
    RubyLLM::Chat.class_eval do
      alias_method :with_tools, :_original_with_tools_for_agent_test if method_defined?(:_original_with_tools_for_agent_test)
    end
  end
end
