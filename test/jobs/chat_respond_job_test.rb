require "test_helper"
require "ostruct"

class ChatRespondJobTest < ActiveJob::TestCase
  include ActionCable::TestHelper

  setup do
    @project = Project.create!(name: "Test Project")
    @chat = @project.create_chat!
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

  test "exception mid-stream: assistant content becomes Error: ..." do
    stub_complete(chunks: [ "partial ", "more" ], raise_at: 1) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    assert_match(/\AError: /, latest_assistant.content)
  end

  test "exception before first chunk: assistant message created with Error: ..." do
    stub_complete(chunks: [], raise_immediately: true) do
      perform_enqueued_jobs { ChatRespondJob.perform_now(@user_message.id) }
    end
    assistant = latest_assistant
    assert assistant.present?, "expected an assistant message to exist"
    assert_match(/\AError: /, assistant.content)
  end

  private

  def latest_assistant
    @chat.messages.where(role: :assistant).order(:id).last
  end

  def stub_complete(chunks:, raise_at: nil, raise_immediately: false)
    ChatCompleteStub.chunks = chunks
    ChatCompleteStub.raise_at = raise_at
    ChatCompleteStub.raise_immediately = raise_immediately

    Chat.class_eval do
      alias_method :_original_complete, :complete if method_defined?(:complete) && !method_defined?(:_original_complete)
      define_method(:complete) do |&block|
        raise StandardError, "boom" if ChatCompleteStub.raise_immediately
        messages.create!(role: :assistant, content: "")
        ChatCompleteStub.chunks.each_with_index do |content, i|
          raise StandardError, "boom" if ChatCompleteStub.raise_at == i
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
      attr_accessor :chunks, :raise_at, :raise_immediately
    end
  end
end
