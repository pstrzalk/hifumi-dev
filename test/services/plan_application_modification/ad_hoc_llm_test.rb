require "test_helper"

class PlanApplicationModification::AdHocLLMTest < ActiveSupport::TestCase
  # Stubs invoke_llm so the test drives build_result with fixture content directly,
  # mimicking what RubyLLM returns from chat.with_schema(...).ask(...).content.
  def with_llm_response(content)
    captured = {}
    original = PlanApplicationModification::AdHocLLM.method(:invoke_llm)

    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm) do |system:, user:, openrouter_api_key:|
      captured[:system] = system
      captured[:user] = user
      captured[:openrouter_api_key] = openrouter_api_key
      content
    end

    yield captured
  ensure
    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end

  def plan_fixture(name)
    JSON.parse(file_fixture("plan_application_modification/#{name}").read)
  end

  test "happy path: returns Result built from schema response" do
    with_llm_response(plan_fixture("valid_plan.json")) do
      result = PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      assert_instance_of PlanApplicationModification::Result, result
      assert_equal "Set primary color to teal across the storybook UI.", result.instruction_description
      assert_equal 1, result.revisions.size
      assert_equal "Update primary color CSS variable to teal", result.revisions.first[:summary]
      assert_match(/--accent/, result.revisions.first[:prompt])
    end
  end

  test "passes system prompt and user prompt with intent to the LLM" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      assert_equal PlanApplicationModification::AdHocLLM::SYSTEM_PROMPT, captured[:system]
      assert_includes captured[:user], "Intent: make banner green"
      assert_not_includes captured[:user], "Clarifications:"
    end
  end

  test "includes clarifications in the user prompt when present" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(
        intent: "make banner green",
        clarifications: { "shade?" => "forest", "icons too?" => "no" },
        context: {},
        openrouter_api_key: "sk-or-test"
      )
      assert_includes captured[:user], "Clarifications:"
      assert_includes captured[:user], "- shade?: forest"
      assert_includes captured[:user], "- icons too?: no"
    end
  end

  test "raises InvalidResponse when LLM returns no content" do
    with_llm_response(nil) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      end
    end
  end

  test "raises InvalidResponse when revisions array is empty" do
    with_llm_response(plan_fixture("empty_revisions.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      end
    end
  end

  test "raises InvalidResponse when instruction_description key missing" do
    with_llm_response(plan_fixture("missing_description.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      end
    end
  end

  test "raises InvalidResponse when revision is missing summary" do
    with_llm_response(plan_fixture("missing_summary.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      end
    end
  end

  test "raises InvalidResponse when revision is missing prompt" do
    with_llm_response(plan_fixture("missing_prompt.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
      end
    end
  end

  test "propagates errors from the LLM" do
    original = PlanApplicationModification::AdHocLLM.method(:invoke_llm)
    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm) do |**|
      raise RuntimeError, "upstream boom"
    end

    assert_raises(RuntimeError) do
      PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test")
    end
  ensure
    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end
end
