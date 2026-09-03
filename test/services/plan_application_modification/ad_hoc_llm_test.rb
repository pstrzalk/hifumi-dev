require "test_helper"

class PlanApplicationModification::AdHocLLMTest < ActiveSupport::TestCase
  # Stubs invoke_llm so the test drives build_result with fixture content directly,
  # mimicking what RubyLLM returns from chat.with_schema(...).ask(...).parsed --
  # v2's .content is the raw String; .parsed is the decoded Hash, and it RAISES
  # on malformed JSON where v1 silently kept the String.
  def with_llm_response(content)
    captured = {}
    original = PlanApplicationModification::AdHocLLM.method(:invoke_llm)

    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm) do |system:, user:, openrouter_api_key:, model:|
      captured[:system] = system
      captured[:user] = user
      captured[:openrouter_api_key] = openrouter_api_key
      captured[:model] = model
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
      result = PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_instance_of PlanApplicationModification::Result, result
      assert_equal "Set primary color to teal across the storybook UI.", result.instruction_description
      assert_equal 1, result.revisions.size
      assert_equal "Update primary color CSS variable to teal", result.revisions.first[:summary]
      assert_match(/--accent/, result.revisions.first[:prompt])
    end
  end

  test "passes system prompt and user prompt with intent to the LLM" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_equal PlanApplicationModification::AdHocLLM::SYSTEM_PROMPT, captured[:system]
      assert_includes captured[:user], "Intent: make banner green"
      assert_not_includes captured[:user], "Clarifications:"
    end
  end

  test "passes the selected model through to the LLM" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-opus-4.6")
      assert_equal "anthropic/claude-opus-4.6", captured[:model]
    end
  end

  test "includes clarifications in the user prompt when present" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(
        intent: "make banner green",
        clarifications: { "shade?" => "forest", "icons too?" => "no" },
        context: {},
        openrouter_api_key: "sk-or-test",
        model: "anthropic/claude-haiku-4.5"
      )
      assert_includes captured[:user], "Clarifications:"
      assert_includes captured[:user], "- shade?: forest"
      assert_includes captured[:user], "- icons too?: no"
    end
  end

  # ---- context[:app_state] — the workspace snapshot ModifyApplication builds ----

  APP_STATE = "## Current application state\n\n### Gems\n\nStandard Rails 8.1 application with Tailwind and Hotwire, on the default Gemfile.".freeze

  test "renders context[:app_state] after the intent, separated by a blank line" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(
        intent: "make banner green", clarifications: {}, context: { app_state: APP_STATE },
        openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5"
      )
      assert_equal "Intent: make banner green\n\n#{APP_STATE}", captured[:user]
    end
  end

  test "an empty context leaves the user prompt byte-identical to the intent line" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_equal "Intent: make banner green", captured[:user]
    end
  end

  test "a nil app_state (workspace not initialized) renders nothing extra" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(intent: "make banner green", clarifications: {}, context: { app_state: nil }, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      assert_equal "Intent: make banner green", captured[:user]
    end
  end

  test "clarifications precede app_state so the request is never buried behind the listing" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationModification::AdHocLLM.call(
        intent: "make banner green",
        clarifications: { "shade?" => "forest" },
        context: { app_state: APP_STATE },
        openrouter_api_key: "sk-or-test",
        model: "anthropic/claude-haiku-4.5"
      )
      assert_equal "Intent: make banner green\nClarifications:\n  - shade?: forest\n\n#{APP_STATE}", captured[:user]
    end
  end

  test "raises InvalidResponse when LLM returns no content" do
    with_llm_response(nil) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  # Message#parsed is JSON.parse, so a top-level array/number/boolean reaches
  # build_result intact. Without the is_a?(Hash) guard `Array(content["revisions"])`
  # raises TypeError, which ModifyApplication#execute does not rescue — the
  # tool_use is then persisted with no tool_result and the chat is dead for good.
  test "raises InvalidResponse when the response parses to a non-object" do
    [ [ { "summary" => "a", "prompt" => "b" } ], 42, true, "plain string" ].each do |content|
      with_llm_response(content) do
        assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse, "expected #{content.class} to be rejected") do
          PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
        end
      end
    end
  end

  # The is_a?(Hash) guard above is TOP-LEVEL only. Each of these parses to an
  # object and clears it, then raises inside the revisions map: NoMethodError
  # for String/Integer/nil#fetch, TypeError for Array#fetch (a Hash reaches the
  # map as [[k, v]] via Array()). Neither is rescued by #execute, so each one
  # would orphan the tool_use and kill the chat permanently.
  test "raises InvalidResponse when revisions hold non-objects" do
    [
      [ "Add a Cart model" ],
      [ 42 ],
      [ nil ],
      "oops",
      { "summary" => "a", "prompt" => "b" }
    ].each do |revisions|
      content = { "instruction_description" => "d", "revisions" => revisions }
      with_llm_response(content) do
        assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse, "expected #{revisions.inspect} to be rejected") do
          PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
        end
      end
    end
  end

  test "raises InvalidResponse when revisions array is empty" do
    with_llm_response(plan_fixture("empty_revisions.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when instruction_description key missing" do
    with_llm_response(plan_fixture("missing_description.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when revision is missing summary" do
    with_llm_response(plan_fixture("missing_summary.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "raises InvalidResponse when revision is missing prompt" do
    with_llm_response(plan_fixture("missing_prompt.json")) do
      assert_raises(PlanApplicationModification::AdHocLLM::InvalidResponse) do
        PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "propagates errors from the LLM" do
    original = PlanApplicationModification::AdHocLLM.method(:invoke_llm)
    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm) do |**|
      raise RuntimeError, "upstream boom"
    end

    assert_raises(RuntimeError) do
      PlanApplicationModification::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
    end
  ensure
    PlanApplicationModification::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
  end
end
