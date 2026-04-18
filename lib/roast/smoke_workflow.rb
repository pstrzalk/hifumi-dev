# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# Smoke workflow: proves the Roast pipeline boots end-to-end WITHOUT calling Claude.
#
# Exercises:
#   - bin/roast wrapper (ANTHROPIC_* unset, PATH pinned to .ruby-version)
#   - Bundler resolves roast-ai from the generator's Gemfile
#   - require_relative from lib/roast/ loads verify_revision
#   - Roast DSL parses (config + execute + ruby blocks)
#
# Does NOT exercise:
#   - agent(...) calls (avoids token spend + skill auto-loading pitfalls)
#   - verify / git / docs steps (no real workspace needed)
#
# Run via tmp/smoke_workflow.sh. Exits 0 if the pipeline is healthy.

require_relative "verify_revision"

execute do
  ruby(:check_env) do
    leaks = %w[ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL BUNDLE_GEMFILE]
            .select { |k| ENV.key?(k) }
    fail!("ENV leaked into roast subprocess: #{leaks.join(', ')}") unless leaks.empty?
    "env clean"
  end

  ruby(:check_ruby) do
    expected = File.read(File.expand_path("../../.ruby-version", __dir__)).strip.sub(/^ruby-/, "")
    fail!("Ruby version mismatch: got #{RUBY_VERSION}, expected #{expected}") unless RUBY_VERSION == expected
    "ruby #{RUBY_VERSION}"
  end

  ruby(:check_verify_revision_loaded) do
    fail!("VerifyRevision not loaded") unless defined?(VerifyRevision)
    fail!("VerifyRevision.run missing") unless VerifyRevision.respond_to?(:run)
    "verify_revision loaded"
  end

  ruby(:report) do
    puts "[smoke] env clean, ruby #{RUBY_VERSION}, verify_revision loaded, roast DSL OK"
    :ok
  end
end
