require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  setup do
    @project = Project.create!(name: "Helper Test", user: users(:owner))
    @chat = @project.create_chat!
    @message = @chat.messages.create!(role: :assistant, content: "")
  end

  test "tool_call_pill_text renders Build started for modify_application with intent" do
    @message.ruby_llm_tool_calls.create!(
      tool_call_id: "tc_modify",
      name: "modify_application",
      arguments: { "intent" => "make banner green" }
    )

    assert_equal "🌀 Build started: make banner green",
                 tool_call_pill_text(@message)
  end

  test "tool_call_pill_text renders Build started for create_application with intent" do
    @message.ruby_llm_tool_calls.create!(
      tool_call_id: "tc_create",
      name: "create_application",
      arguments: { "intent" => "build a todo list" }
    )

    assert_equal "🌀 Build started: build a todo list",
                 tool_call_pill_text(@message)
  end

  test "tool_call_pill_text falls back to generic Build started when intent is missing" do
    @message.ruby_llm_tool_calls.create!(
      tool_call_id: "tc_no_intent",
      name: "modify_application",
      arguments: {}
    )

    assert_equal "🌀 Build started", tool_call_pill_text(@message)
  end

  test "tool_call_pill_text falls back to running:<names> for unknown tools" do
    @message.ruby_llm_tool_calls.create!(
      tool_call_id: "tc_other",
      name: "some_other_tool",
      arguments: {}
    )

    assert_equal "running: some_other_tool", tool_call_pill_text(@message)
  end

  test "message_body_html formats a finished assistant message" do
    @message.update!(content: "1. **hi**")

    html = message_body_html(@message)

    assert_includes html, "<strong>hi</strong>"
    assert_includes html, "<ol>"
    refute_includes html, "**"
    assert_predicate html, :html_safe?
  end

  test "message_body_html leaves a mid-stream assistant message plain" do
    @message.update!(content: "1. **hi**")

    html = message_body_html(@message, streaming: true)

    assert_equal "1. **hi**", html
    refute_predicate html, :html_safe?
  end

  test "message_body_html leaves a user message plain" do
    user_message = @chat.messages.create!(role: :user, content: "1. **hi**")

    html = message_body_html(user_message)

    assert_equal "1. **hi**", html
    refute_predicate html, :html_safe?
  end

  test "message_body_class adds msg-prose only for a finished assistant message" do
    assert_equal "msg-body msg-prose", message_body_class(@message)
  end

  test "message_body_class stays msg-body for a user message" do
    user_message = @chat.messages.create!(role: :user, content: "hi")

    assert_equal "msg-body", message_body_class(user_message)
  end

  test "message_body_class stays msg-body mid-stream" do
    assert_equal "msg-body", message_body_class(@message, streaming: true)
  end
end
