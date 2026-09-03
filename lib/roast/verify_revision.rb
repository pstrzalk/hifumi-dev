# frozen_string_literal: true

# Deterministic verification of a Rails workspace.
# Run both from the workflow and standalone (bin/verify).

module VerifyRevision
  CHECKS = %i[bundle_check db_prepare herb_lint boot_check rails_test].freeze

  # Short-circuit on bundle_check failure: every later check (db_prepare,
  # herb_lint, boot_check, rails_test) loads bundler and would emit the same
  # Bundler::GemNotFound stacktrace. Surfacing all four padded the fix-agent
  # prompt with 4× the same noise, costing input tokens with zero new info.
  def self.run(workspace)
    results = []
    CHECKS.each do |check|
      result = perform(check, workspace)
      next if result.nil?

      results << result
      if check == :bundle_check && !result[:passed]
        break # bundle_check is the foundation — nothing downstream can succeed without it.
      end
    end

    {
      checks: results,
      passed: results.select { |r| r[:passed] },
      failed: results.reject { |r| r[:passed] }
    }
  end

  def self.failed?(result)
    result[:failed].any?
  end

  def self.format_errors(result)
    result[:failed].map { |c| "#{c[:name]}:\n#{c[:output]}" }.join("\n\n---\n\n")
  end

  def self.summary(result)
    result[:checks].map { |c| "#{c[:passed] ? 'PASS' : 'FAIL'} #{c[:name]}" }.join("\n")
  end

  def self.perform(check, workspace)
    case check
    when :bundle_check
      run_cmd(workspace, "bundle check", "bundle check")
    when :db_prepare
      run_cmd(workspace, "bin/rails db:prepare", "db:prepare")
    when :herb_lint
      return nil unless gem_available?(workspace, "herb")
      run_cmd(workspace, "bundle exec herb lint app/views/", "herb lint")
    when :boot_check
      run_cmd(workspace, 'bin/rails runner "puts :ok"', "boot check")
    when :rails_test
      return nil if Dir.glob("#{workspace}/test/**/*_test.rb").empty?
      run_cmd(workspace, "bin/rails test", "rails test")
    end
  end

  def self.run_cmd(workspace, cmd, name)
    output = with_clean_bundler_env { `cd #{workspace} && #{cmd} 2>&1` }
    { name: name, passed: $?.success?, output: output }
  end

  def self.gem_available?(workspace, name)
    with_clean_bundler_env { system("cd #{workspace} && bundle show #{name} > /dev/null 2>&1") }
  end

  # Roast runs under `bundle exec`, which sets BUNDLE_GEMFILE to the generator's
  # Gemfile and RUBYOPT=-rbundler/setup. Subprocess `bundle check` / `bin/rails`
  # against the workspace must not see those, or they resolve against the wrong
  # bundle. Bundler.with_unbundled_env removes them — but it removes EVERY
  # BUNDLE_* variable, the image-level ones included (this comment used to claim
  # otherwise; production disproved it on 2026-09-03). Without BUNDLE_PATH,
  # Bundler looks under $GEM_HOME/gems instead of $BUNDLE_PATH/ruby/<abi>/gems
  # and reports the whole lockfile missing; without BUNDLE_WITHOUT it wants the
  # development group the image never installs. Both are restored here from the
  # env as it was before `bundle exec`. In dev neither is set, so nothing is
  # added. The claude wrapper in the Dockerfile does the same for the agent,
  # which roast spawns unbundled as well.
  IMAGE_BUNDLER_ENV = %w[BUNDLE_PATH BUNDLE_WITHOUT].freeze

  def self.with_clean_bundler_env
    Bundler.with_unbundled_env do
      original = Bundler.original_env
      IMAGE_BUNDLER_ENV.each { |key| ENV[key] = original[key] if original.key?(key) }
      yield
    end
  end
end
