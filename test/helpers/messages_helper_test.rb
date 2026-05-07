require "test_helper"

class MessagesHelperTest < ActionView::TestCase
  setup do
    @project = Project.create!(name: "Helper Test", user: users(:owner))
    @chat = @project.create_chat!
    @message = @chat.messages.create!(role: :assistant, content: "")
  end

  test "tool_call_pill_text renders Build started for modify_application with intent" do
    @message.tool_calls.create!(
      tool_call_id: "tc_modify",
      name: "modify_application",
      arguments: { "intent" => "make banner green" }
    )

    assert_equal "🌀 Build started: make banner green",
                 tool_call_pill_text(@message)
  end

  test "tool_call_pill_text renders Build started for create_application with intent" do
    @message.tool_calls.create!(
      tool_call_id: "tc_create",
      name: "create_application",
      arguments: { "intent" => "build a todo list" }
    )

    assert_equal "🌀 Build started: build a todo list",
                 tool_call_pill_text(@message)
  end

  test "tool_call_pill_text falls back to generic Build started when intent is missing" do
    @message.tool_calls.create!(
      tool_call_id: "tc_no_intent",
      name: "modify_application",
      arguments: {}
    )

    assert_equal "🌀 Build started", tool_call_pill_text(@message)
  end

  test "tool_call_pill_text falls back to running:<names> for unknown tools" do
    @message.tool_calls.create!(
      tool_call_id: "tc_other",
      name: "some_other_tool",
      arguments: {}
    )

    assert_equal "running: some_other_tool", tool_call_pill_text(@message)
  end
end
