# frozen_string_literal: true

# Deterministic verification of a Rails workspace.
# Uruchamiane zarówno z workflow'u jak i standalone (bin/verify).

module VerifyRevision
  CHECKS = %i[bundle_check db_prepare herb_lint boot_check rails_test].freeze

  def self.run(workspace)
    results = CHECKS.map { |check| perform(check, workspace) }.compact
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
    output = `cd #{workspace} && #{cmd} 2>&1`
    { name: name, passed: $?.success?, output: output }
  end

  def self.gem_available?(workspace, name)
    system("cd #{workspace} && bundle show #{name} > /dev/null 2>&1")
  end
end
