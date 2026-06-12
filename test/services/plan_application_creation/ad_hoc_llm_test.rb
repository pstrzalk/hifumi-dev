require "test_helper"

class PlanApplicationCreation::AdHocLLMTest < ActiveSupport::TestCase
  # Stubs invoke_llm so the test drives build_result with fixture content directly,
  # mimicking what RubyLLM returns from chat.with_schema(...).ask(...).content.
  def with_llm_response(content)
    captured = {}
    original = PlanApplicationCreation::AdHocLLM.method(:invoke_llm)

    PlanApplicationCreation::AdHocLLM.define_singleton_method(:invoke_llm) do |system:, user:, openrouter_api_key:, model:|
      captured[:system] = system
      captured[:user] = user
      captured[:openrouter_api_key] = openrouter_api_key
      captured[:model] = model
      content
    end

    yield captured
  ensure
    PlanApplicationCreation::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end

  def plan_fixture(name)
    JSON.parse(file_fixture("plan_application_creation/#{name}").read)
  end

  test "happy path: returns Result built from schema response" do
    with_llm_response(plan_fixture("valid_plan.json")) do
      result = PlanApplicationCreation::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_instance_of PlanApplicationCreation::Result, result
      assert_equal "Simple todo list with Tailwind", result.instruction_description
      assert_equal 3, result.revisions.size
      assert_equal "Add Task model", result.revisions.first[:summary]
      assert_match(/Task model/, result.revisions.first[:prompt])
    end
  end

  test "passes system prompt and user prompt with intent to the LLM" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationCreation::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_equal PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT, captured[:system]
      assert_includes captured[:user], "Intent: todo list"
      assert_not_includes captured[:user], "Clarifications:"
    end
  end

  test "passes the selected model through to the LLM" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationCreation::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-opus-4.6")
      assert_equal "anthropic/claude-opus-4.6", captured[:model]
    end
  end

  test "includes clarifications in the user prompt when present" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationCreation::AdHocLLM.call(
        intent: "flower shop",
        clarifications: { "auth?" => "yes, Devise", "payments?" => "Stripe" },
        context: {},
        openrouter_api_key: "sk-or-test",
        model: "anthropic/claude-haiku-4.5"
      )
      assert_includes captured[:user], "Clarifications:"
      assert_includes captured[:user], "- auth?: yes, Devise"
      assert_includes captured[:user], "- payments?: Stripe"
    end
  end

  test "raises InvalidResponse when LLM returns no content" do
    with_llm_response(nil) do
      assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse) do
        PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when revisions array is empty" do
    with_llm_response(plan_fixture("empty_revisions.json")) do
      assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse) do
        PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when instruction_description key missing" do
    with_llm_response(plan_fixture("missing_description.json")) do
      assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse) do
        PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when revision is missing summary" do
    with_llm_response(plan_fixture("missing_summary.json")) do
      assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse) do
        PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when revision is missing prompt" do
    with_llm_response(plan_fixture("missing_prompt.json")) do
      assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse) do
        PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "propagates errors from the LLM" do
    original = PlanApplicationCreation::AdHocLLM.method(:invoke_llm)
    PlanApplicationCreation::AdHocLLM.define_singleton_method(:invoke_llm) do |**|
      raise RuntimeError, "upstream boom"
    end

    assert_raises(RuntimeError) do
      PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
    end
  ensure
    PlanApplicationCreation::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end
end
