require "test_helper"
require Rails.root.join("lib/roast/workflow_env")

class Roast::WorkflowEnvTest < ActiveSupport::TestCase
  # --- claude_model ------------------------------------------------------

  test "claude_model defaults to sonnet" do
    assert_equal "sonnet", Roast::WorkflowEnv.claude_model({})
  end

  test "claude_model uses RAILS_APP_GENERATOR_MODEL when set" do
    assert_equal "haiku",
                 Roast::WorkflowEnv.claude_model({ "RAILS_APP_GENERATOR_MODEL" => "haiku" })
  end

  # --- docs_model --------------------------------------------------------

  test "docs_model defaults to haiku (regression guard for 13f22a8 cost cut)" do
    # If this default silently flips back to sonnet, update_docs cost
    # reverts from ~$0.10 to ~$0.50/revision. Lock the cheap default.
    assert_equal "haiku", Roast::WorkflowEnv.docs_model({})
  end

  test "docs_model uses RAILS_APP_GENERATOR_DOCS_MODEL when set" do
    assert_equal "sonnet",
                 Roast::WorkflowEnv.docs_model({ "RAILS_APP_GENERATOR_DOCS_MODEL" => "sonnet" })
  end

  # --- fix_budget_usd ----------------------------------------------------

  test "fix_budget_usd defaults to 0.50" do
    assert_equal "0.50", Roast::WorkflowEnv.fix_budget_usd({})
  end

  test "fix_budget_usd uses override when set" do
    assert_equal "1.25",
                 Roast::WorkflowEnv.fix_budget_usd({ "RAILS_APP_GENERATOR_FIX_BUDGET_USD" => "1.25" })
  end

  test "fix_budget_usd raises ArgumentError on non-numeric value (fail-fast at load)" do
    # If we passed garbage through, claude CLI would fail mid-run with an
    # opaque error. Catch it at workflow startup instead.
    assert_raises(ArgumentError) do
      Roast::WorkflowEnv.fix_budget_usd({ "RAILS_APP_GENERATOR_FIX_BUDGET_USD" => "hello" })
    end
    assert_raises(ArgumentError) do
      Roast::WorkflowEnv.fix_budget_usd({ "RAILS_APP_GENERATOR_FIX_BUDGET_USD" => "" })
    end
  end

  # --- workspace ---------------------------------------------------------

  test "workspace raises a clear error when RAILS_APP_GENERATOR_WORKSPACE is missing" do
    err = assert_raises(RuntimeError) { Roast::WorkflowEnv.workspace({}) }
    assert_match(/RAILS_APP_GENERATOR_WORKSPACE/, err.message)
  end

  test "workspace returns the env value when set" do
    assert_equal "/tmp/ws",
                 Roast::WorkflowEnv.workspace({ "RAILS_APP_GENERATOR_WORKSPACE" => "/tmp/ws" })
  end
end
