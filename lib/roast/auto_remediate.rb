# frozen_string_literal: true

# Deterministic, agent-free remediation for known verify failures.
#
# Run after VerifyRevision fails, BEFORE handing the errors to a Claude agent.
# Each recipe matches a specific error pattern and applies a known fix in
# pure Ruby/shell. If a recipe applies, re-run verify. If verify now passes,
# skip the (expensive) LLM remediation loop entirely.
#
# Empirical impact: a single fix-agent turn averages $0.05–$1.00 on sonnet.
# Catching even one recipe per workflow saves that.
require "shellwords"

module AutoRemediate
  # Each recipe: { match: Regexp, fix: ->(workspace, errors_text) { ... } }
  # The fix proc returns a short string describing what it did, or nil if
  # it couldn't apply after all (e.g. the shell call failed).
  RECIPES = [
    {
      name: "bundler missing gems",
      match: /Install missing gems with `bundle install`|Bundler::GemNotFound|Could not find .+ in locally installed gems/,
      fix: ->(mod, workspace) {
        mod.shell(workspace, "bundle install --jobs 4 > /tmp/auto_remediate_bundle.log 2>&1") ? "ran `bundle install`" : nil
      }
    },
    {
      name: "master.key permission denied",
      match: /config\/master\.key.+Permission denied|Permission denied.+config\/master\.key/,
      fix: ->(mod, workspace) {
        mod.shell(workspace, "git checkout HEAD -- config/master.key > /dev/null 2>&1") ? "restored config/master.key from git" : nil
      }
    }
  ].freeze

  # Try every matching recipe. Returns an array of human-readable strings
  # describing fixes applied; empty if no recipe matched (or none applied
  # cleanly). Caller is responsible for re-running verify afterwards.
  def self.run(workspace, errors_text)
    applied = []
    RECIPES.each do |recipe|
      next unless recipe[:match].match?(errors_text)

      result = recipe[:fix].call(self, workspace)
      applied << "#{recipe[:name]}: #{result}" if result
    end
    applied
  end

  # Single shell seam — recipes route through here so tests can stub it.
  def self.shell(workspace, cmd)
    system("cd #{Shellwords.escape(workspace)} && #{cmd}")
  end
end
