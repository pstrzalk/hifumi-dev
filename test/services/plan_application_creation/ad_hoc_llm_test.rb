require "test_helper"

class PlanApplicationCreation::AdHocLLMTest < ActiveSupport::TestCase
  # Stubs invoke_llm so the test drives build_result with fixture content directly,
  # mimicking what RubyLLM returns from chat.with_schema(...).ask(...).parsed --
  # v2's .content is the raw String; .parsed is the decoded Hash, and it RAISES
  # on malformed JSON where v1 silently kept the String.
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
      # The photo inventory is appended at assembly time; the hand-written
      # prompt still leads. Asserted in full further down.
      assert captured[:system].start_with?(PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT)
      assert_includes captured[:user], "Intent: todo list"
      assert_not_includes captured[:user], "Clarifications:"
    end
  end

  # ---- the system prompt states only what a fresh app will have ----
  # This planner runs before `rails new`, so its prompt is its only lever. It
  # used to assert Devise was installed; the workspace never has it. Sign-in is
  # planned as has_secure_password + sessions, and the default stack is named
  # as "default Rails 8", never enumerated.

  test "system prompt never names Devise-class gems, hifumi design tokens, or the default stack's parts" do
    refute_match(/devise|pundit|cancancan|sidekiq|rspec|spec\/|factory_bot|factorybot|simplecov|--accent|--paper|--ink|propshaft|importmap|solid_/i,
                 PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT)
  end

  test "system prompt frames the stack positively: default Rails 8, default Gemfile, has_secure_password" do
    prompt = PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT
    assert_includes prompt, "default Rails 8 app"
    assert_includes prompt, "default Gemfile"
    assert_includes prompt, "has_secure_password"
  end

  # The range alone reads as a target rather than a limit -- probed against the
  # live planner, both "a todo list app" and a finance tracker came back at
  # exactly 8, and the earlier "3 to 6" wording anchored on 6 the same way. The
  # low-end directive is what counteracts it, so it is guarded alongside the
  # numbers. Same shape as the modification prompt's "PREFER A SINGLE REVISION".
  test "system prompt asks for 4 to 8 revisions and steers to the low end" do
    prompt = PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT
    assert_includes prompt, "4 to 8 revisions"
    assert_includes prompt, "PREFER THE SMALLEST NUMBER"
    assert_includes prompt, "Never split one unit of work"
  end

  test "system prompt pins tests to Minitest under test/ and closes the test stack" do
    prompt = PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT
    assert_includes prompt, "Minitest under `test/`"
    assert_includes prompt, "bin/rails test"
    assert_includes prompt, "test/models/<name>_test.rb"
    assert_includes prompt, "plan no additional testing gems"
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

  # Message#parsed is JSON.parse, so a top-level array/number/boolean reaches
  # build_result intact. Without the is_a?(Hash) guard `Array(content["revisions"])`
  # raises TypeError, which CreateApplication#execute does not rescue — the
  # tool_use is then persisted with no tool_result and the chat is dead for good.
  test "raises InvalidResponse when the response parses to a non-object" do
    [ [ { "summary" => "a", "prompt" => "b" } ], 42, true, "plain string" ].each do |content|
      with_llm_response(content) do
        assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse, "expected #{content.class} to be rejected") do
          PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
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
        assert_raises(PlanApplicationCreation::AdHocLLM::InvalidResponse, "expected #{revisions.inspect} to be rejected") do
          PlanApplicationCreation::AdHocLLM.call(intent: "x", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
        end
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

  # ---- the photo inventory is appended to the system prompt ----
  # SYSTEM_PROMPT itself stays the frozen .md file (the refute_match guard above
  # asserts on it); the inventory is derived from public/photos/ and joined on at
  # assembly time, so these assert on what actually reaches the model.

  test "system prompt sent to the LLM carries the photo inventory after the hand-written prompt" do
    with_llm_response(plan_fixture("valid_plan.json")) do |captured|
      PlanApplicationCreation::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {}, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")

      system = captured[:system]
      assert system.start_with?(PlanApplicationCreation::AdHocLLM::SYSTEM_PROMPT),
             "the hand-written prompt must still lead"
      assert_includes system, "## Photos available"
      assert_includes system, Photos.all.first.filename
    end
  end

  test "the appended photo block trips none of the guards asserted on SYSTEM_PROMPT" do
    refute_match(/devise|pundit|cancancan|sidekiq|rspec|spec\/|factory_bot|factorybot|simplecov|--accent|--paper|--ink|propshaft|importmap|solid_/i,
                 PlanApplicationCreation::AdHocLLM.system_prompt)
  end
end
