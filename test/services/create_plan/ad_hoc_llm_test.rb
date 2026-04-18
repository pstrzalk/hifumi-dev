require "test_helper"

class CreatePlan::AdHocLLMTest < ActiveSupport::TestCase
  # Stubs invoke_llm so the test can drive the tool directly with fixture args,
  # mimicking what RubyLLM does when the real LLM invokes emit_plan.
  def with_tool_invocation(tool_args)
    captured = {}
    original = CreatePlan::AdHocLLM.method(:invoke_llm)

    CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm) do |system:, user:|
      captured[:system] = system
      captured[:user] = user
      tool = CreatePlan::AdHocLLM::EmitPlan.new
      tool.call(tool_args) unless tool_args.nil?
      tool
    end

    yield captured
  ensure
    CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end

  def plan_fixture_args(name)
    JSON.parse(file_fixture("create_plan/#{name}").read)
  end

  test "happy path: returns Result built from tool call args" do
    with_tool_invocation(plan_fixture_args("valid_plan.json")) do
      result = CreatePlan::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {})
      assert_instance_of CreatePlan::Result, result
      assert_equal "Simple todo list with Tailwind", result.instruction_description
      assert_equal 3, result.revisions.size
      assert_equal "Add Task model", result.revisions.first[:summary]
      assert_match(/Task model/, result.revisions.first[:prompt])
    end
  end

  test "passes system prompt and user prompt with intent to the LLM" do
    with_tool_invocation(plan_fixture_args("valid_plan.json")) do |captured|
      CreatePlan::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {})
      assert_equal CreatePlan::AdHocLLM::SYSTEM_PROMPT, captured[:system]
      assert_includes captured[:user], "Intent: todo list"
      assert_not_includes captured[:user], "Clarifications:"
    end
  end

  test "includes clarifications in the user prompt when present" do
    with_tool_invocation(plan_fixture_args("valid_plan.json")) do |captured|
      CreatePlan::AdHocLLM.call(
        intent: "flower shop",
        clarifications: { "auth?" => "yes, Devise", "payments?" => "Stripe" },
        context: {}
      )
      assert_includes captured[:user], "Clarifications:"
      assert_includes captured[:user], "- auth?: yes, Devise"
      assert_includes captured[:user], "- payments?: Stripe"
    end
  end

  test "raises InvalidResponse when LLM never calls emit_plan" do
    with_tool_invocation(nil) do
      assert_raises(CreatePlan::AdHocLLM::InvalidResponse) do
        CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
      end
    end
  end

  test "raises InvalidResponse when revisions array is empty" do
    with_tool_invocation(plan_fixture_args("empty_revisions.json")) do
      assert_raises(CreatePlan::AdHocLLM::InvalidResponse) do
        CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
      end
    end
  end

  test "raises InvalidResponse when instruction_description key missing" do
    with_tool_invocation(plan_fixture_args("missing_description.json")) do
      assert_raises(CreatePlan::AdHocLLM::InvalidResponse) do
        CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
      end
    end
  end

  test "raises InvalidResponse when revision is missing summary" do
    with_tool_invocation(plan_fixture_args("missing_summary.json")) do
      assert_raises(CreatePlan::AdHocLLM::InvalidResponse) do
        CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
      end
    end
  end

  test "raises InvalidResponse when revision is missing prompt" do
    with_tool_invocation(plan_fixture_args("missing_prompt.json")) do
      assert_raises(CreatePlan::AdHocLLM::InvalidResponse) do
        CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
      end
    end
  end

  test "propagates errors from the LLM" do
    original = CreatePlan::AdHocLLM.method(:invoke_llm)
    CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm) do |**|
      raise RuntimeError, "upstream boom"
    end

    assert_raises(RuntimeError) do
      CreatePlan::AdHocLLM.call(intent: "x", clarifications: {}, context: {})
    end
  ensure
    CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end
end
