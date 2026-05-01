require "test_helper"

class SuggestPromptsTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @project = Project.create!(name: "Todo", user: users(:owner))
    @stream_name = @project.to_gid_param
    @tool = SuggestPrompts.new(project: @project)
  end

  test "returns a Hash with the sanitised prompts" do
    result = @tool.execute(prompts: [ "add auth", "add admin" ])
    assert_equal({ prompts: [ "add auth", "add admin" ] }, result)
  end

  test "strips whitespace and drops empty strings" do
    result = @tool.execute(prompts: [ "  add auth ", "", "   ", "seed data" ])
    assert_equal [ "add auth", "seed data" ], result[:prompts]
  end

  test "caps the list at 5 prompts" do
    prompts = (1..8).map { |i| "prompt #{i}" }
    result = @tool.execute(prompts: prompts)
    assert_equal 5, result[:prompts].size
    assert_equal prompts.first(5), result[:prompts]
  end

  test "broadcasts a turbo stream replace to the project stream targeting #suggestions" do
    assert_broadcasts(@stream_name, 1) do
      @tool.execute(prompts: [ "add auth", "seed data" ])
    end

    raw = broadcasts(@stream_name).last
    assert raw.present?, "expected a broadcast on #{@stream_name}"
    payload = JSON.parse(raw)
    assert_includes payload, 'target="suggestions"'
    assert_includes payload, 'action="replace"'
    assert_includes payload, "add auth"
    assert_includes payload, "seed data"
  end

  test "empty prompts: still broadcasts, frame renders empty" do
    assert_broadcasts(@stream_name, 1) do
      @tool.execute(prompts: [])
    end

    raw = broadcasts(@stream_name).last
    payload = JSON.parse(raw)
    assert_includes payload, 'target="suggestions"'
    assert_includes payload, 'action="replace"'
  end

  test "second call within the same user turn: returns an error and does not broadcast" do
    chat = GeneratorAgent.create!(project: @project)
    user_msg = chat.messages.create!(role: :user, content: "yes")
    asst1    = chat.messages.create!(role: :assistant, content: "first")
    ToolCall.create!(message: asst1, name: "suggest_prompts", tool_call_id: "toolu_a", arguments: {})
    chat.messages.create!(role: :tool, tool_call_id: ToolCall.last.id, content: "{}")
    asst2    = chat.messages.create!(role: :assistant, content: "second")
    ToolCall.create!(message: asst2, name: "suggest_prompts", tool_call_id: "toolu_b", arguments: {})

    assert_no_broadcasts(@stream_name) do
      result = @tool.execute(prompts: [ "x" ])
      assert result[:error].present?, "expected an :error key"
      assert_match(/already called this turn/, result[:error])
    end
  end

  test "first call after a new user turn still succeeds even if previous turns called the tool" do
    chat = GeneratorAgent.create!(project: @project)
    # Previous turn: one suggest_prompts call already happened.
    prev_user = chat.messages.create!(role: :user, content: "earlier")
    prev_asst = chat.messages.create!(role: :assistant, content: "")
    ToolCall.create!(message: prev_asst, name: "suggest_prompts", tool_call_id: "toolu_old", arguments: {})
    chat.messages.create!(role: :tool, tool_call_id: ToolCall.last.id, content: "{}")
    # New turn opens.
    chat.messages.create!(role: :user, content: "yes")
    new_asst = chat.messages.create!(role: :assistant, content: "")
    ToolCall.create!(message: new_asst, name: "suggest_prompts", tool_call_id: "toolu_new", arguments: {})

    assert_broadcasts(@stream_name, 1) do
      result = @tool.execute(prompts: [ "x" ])
      assert_equal [ "x" ], result[:prompts]
    end
  end
end
