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

  test "system_injected user messages are not visible_in_chat" do
    msg = @chat.messages.create!(role: :user, content: "hi", system_injected: true)
    refute msg.visible_in_chat?
  end

  test "regular user messages are visible_in_chat" do
    msg = @chat.messages.create!(role: :user, content: "hi", system_injected: false)
    assert msg.visible_in_chat?
  end

  # The tool_call? disjunct of visible_in_chat?. The one other test that puts a
  # tool call on a message gives it prose too, so content.present? short-circuits
  # and this branch is never reached there. If it regressed, message_row_class
  # would return "hidden" and every build-started pill would vanish silently.
  test "an assistant message with no prose is visible_in_chat when it carries a tool call" do
    msg = @chat.messages.create!(role: :assistant, content: "")
    msg.ruby_llm_tool_calls.create!(
      tool_call_id: "tc_visible", name: "create_application",
      arguments: { "intent" => "habit tracker" }
    )

    assert msg.visible_in_chat?
  end

  test "an assistant message with neither prose nor a tool call is not visible_in_chat" do
    msg = @chat.messages.create!(role: :assistant, content: "")

    refute msg.visible_in_chat?
  end

  test "system_injected messages do not enqueue an append broadcast" do
    assert_no_enqueued_jobs(only: Turbo::Streams::ActionBroadcastJob) do
      @chat.messages.create!(role: :user, content: "hi", system_injected: true)
    end
  end

  # Reproduces the production sequence: create (enqueues but does not run the
  # broadcast job), then chunks land via update_columns, then the job renders the
  # partial from a GlobalID reload — so the appended row already carries
  # half-written markdown by render time.
  test "append broadcast renders plain text even when chunks landed before the job ran" do
    message = @chat.messages.create!(role: :assistant, content: "")
    message.update_columns(content: "**bold**")

    perform_enqueued_jobs
    payload = JSON.parse(broadcasts(@stream_name).last)

    assert_includes payload, "**bold**"
    refute_includes payload, "<strong>bold</strong>"
  end

  # The third broadcast site, and the only one that SHOULD format: the final save
  # after streaming ends. Its two siblings (append here, mid-stream in
  # chat_respond_job_test) assert the opposite, so without this a stray
  # `streaming: true` on broadcast_replace_message would leave every finished
  # reply plain with a fully green suite.
  test "replace broadcast formats a finished assistant reply as markdown" do
    message = @chat.messages.create!(role: :assistant, content: "")
    perform_enqueued_jobs   # drain the create/append broadcast first

    perform_enqueued_jobs { message.update!(content: "**bold**") }
    payload = JSON.parse(broadcasts(@stream_name).last)

    assert_includes payload, 'action="replace"'
    assert_includes payload, "<strong>bold</strong>"
    refute_includes payload, "**bold**"
  end

  test "creating a message touches the chat's project (bumps active timestamp)" do
    travel_to 1.hour.from_now do
      assert_changes -> { @project.reload.updated_at } do
        @chat.messages.create!(role: :user, content: "hello")
      end
    end
  end
end
