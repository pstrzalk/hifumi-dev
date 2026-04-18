require "test_helper"

class MessageTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionCable::TestHelper

  setup do
    @chat = chats(:flowers)
    @project = @chat.project
    @stream_name = @project.to_gid_param
  end

  test "create enqueues a Turbo broadcast job targeted at the project stream" do
    assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
      @chat.messages.create!(role: :user, content: "hello")
    end
  end

  test "broadcast runs exactly once on create" do
    assert_broadcasts(@stream_name, 1) do
      perform_enqueued_jobs do
        @chat.messages.create!(role: :user, content: "hello")
      end
    end
  end

  test "broadcast appends to the #messages target with the messages/message partial" do
    message = nil
    perform_enqueued_jobs do
      message = @chat.messages.create!(role: :user, content: "hello there")
    end

    raw = broadcasts(@stream_name).last
    assert raw.present?, "expected a broadcast on #{@stream_name}"
    payload = JSON.parse(raw)
    assert_includes payload, "id=\"#{ActionView::RecordIdentifier.dom_id(message)}\""
    assert_includes payload, "hello there"
    assert_includes payload, 'target="messages"'
    assert_includes payload, 'action="append"'
  end
end
