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

  # Roast runs under `bundle exec`, so ENV has the spike's BUNDLE_GEMFILE.
  # The shell into the workspace must get a clean env so the workspace's Gemfile is visible.
  def self.with_clean_bundler_env
    saved = {}
    bundler_keys = ENV.keys.select { |k| k.start_with?("BUNDLE", "BUNDLER", "RUBYOPT") }
    bundler_keys.each { |k| saved[k] = ENV.delete(k) }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end
end
