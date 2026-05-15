# frozen_string_literal: true

# Single gateway for the four ENV vars that configure revision_workflow.rb.
#
# Centralizing here lets us:
#   - unit-test defaults / overrides / validation without loading Roast
#   - fail-fast at workflow startup on garbage input (e.g. a non-numeric
#     fix budget would otherwise reach claude CLI as `--max-budget-usd hello`
#     and produce an opaque crash mid-run)
#
# Each method takes an env hash so tests can supply their own without
# touching the real ENV. revision_workflow.rb passes the default ENV.
module Roast
  module WorkflowEnv
    # Required. Path to the Rails workspace this revision will operate on.
    def self.workspace(env = ENV)
      env.fetch("HIFUMI_DEV_WORKSPACE") do
        raise "HIFUMI_DEV_WORKSPACE env var is required (path to Rails workspace)."
      end
    end

    # Model used for the main code-generation and fix agents.
    def self.claude_model(env = ENV)
      env.fetch("HIFUMI_DEV_MODEL", "sonnet")
    end

    # Model used for update_docs. Haiku because it's a summarization step
    # operating on a diff already in the prompt — reasoning isn't load-bearing.
    # Switching this back to sonnet would re-introduce the ~$0.5/revision
    # regression that 13f22a8 cut.
    def self.docs_model(env = ENV)
      env.fetch("HIFUMI_DEV_DOCS_MODEL", "haiku")
    end

    # Per-iteration $ ceiling on agent(:fix). The W2.R loop runs up to 2
    # iterations, so total worst-case spend on remediation is 2x this.
    # Default $0.50 is generous vs historical legitimate fixes (bundle
    # install $0.05, master.key restore $0.31) but tight enough to kill
    # runaway flails (49-turn / $0.99 permission chase in
    # tmp/simple_application_run_kamal.log rev 14).
    #
    # Validated as a float at workflow load so a bad env value
    # (`HIFUMI_DEV_FIX_BUDGET_USD=hello`) crashes here with a
    # clear ArgumentError instead of reaching claude CLI as
    # `--max-budget-usd hello` and producing an opaque mid-run failure.
    def self.fix_budget_usd(env = ENV)
      raw = env.fetch("HIFUMI_DEV_FIX_BUDGET_USD", "0.50")
      Float(raw)
      raw
    end
  end
end
