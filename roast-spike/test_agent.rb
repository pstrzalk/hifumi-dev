# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# Test: agent cog z Claude CLI + working_directory
# Generuje prosty plik Ruby i weryfikuje
#
# Uruchomienie: bundle exec roast test_agent.rb

WORKSPACE = File.expand_path("tmp/agent_test", __dir__)

config do
  agent do
    provider :claude
    model "haiku"
    working_directory WORKSPACE
    skip_permissions!
    show_stats!
  end

  cmd { display! }
end

execute do
  # Setup workspace
  cmd(:setup) do |my|
    my.command = "sh"
    my.args = ["-c", "rm -rf #{WORKSPACE} && mkdir -p #{WORKSPACE} && cd #{WORKSPACE} && git init -b main"]
  end

  # Agent generates a Ruby file
  agent(:generate) do
    <<~PROMPT
      Create a file calculator.rb with a Calculator class that has:
      - add(a, b) method
      - subtract(a, b) method
      - multiply(a, b) method

      Also create calculator_test.rb using minitest that tests all three methods.
      Use require_relative "calculator" in the test file.

      Only create these two files, nothing else.
    PROMPT
  end

  # Verify: file exists and test passes
  cmd(:verify) do |my|
    my.command = "ruby"
    my.args = ["-I#{WORKSPACE}", "#{WORKSPACE}/calculator_test.rb"]
  end

  # Commit
  cmd(:commit) do |my|
    my.command = "sh"
    my.args = ["-c", "cd #{WORKSPACE} && git add -A && git commit -m 'Add Calculator with tests'"]
  end

  ruby(:report) do
    sha = `cd #{WORKSPACE} && git rev-parse --short HEAD`.strip
    files = Dir.glob("#{WORKSPACE}/*.rb").map { File.basename(_1) }
    puts "[done] Committed: #{sha}"
    puts "[done] Files: #{files.join(", ")}"
    { sha: sha, files: files }
  end
end
