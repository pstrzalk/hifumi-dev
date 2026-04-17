# frozen_string_literal: true

# W1: Generation of a new application (simplified for the spike)
# Creates a Rails app from scratch and executes revisions.
#
# Run:
#   bin/roast execute new_app_workflow.rb -- \
#     --app-name flower-shop \
#     --workspace /tmp \
#     --prompt "App for selling flowers. Customer browses bouquets, adds to cart, places an order with a delivery address."

config do
  agent do
    provider :claude
    model "sonnet"
  end

  chat(:planner) do
    provider :anthropic
    model "claude-sonnet-4-20250514"
  end

  cmd do
    display!
  end

  map(:revisions) do
    parallel 1 # Sequential — each revision builds on the previous one
  end
end

# --- Scope: execution of one revision (W2 simplified) ---

execute(:execute_revision) do
  # Implement
  agent(:generate) do |_, revision|
    workspace = kwarg(:workspace_path)
    <<~PROMPT
      ## Task
      #{revision[:prompt]}

      ## Rules
      - Rails Way: conventions, generators, built-in solutions
      - Tailwind CSS, Hotwire (Turbo + Stimulus)
      - SQLite, Solid Queue/Cable/Cache
      - Minitest, not RSpec
      - Write tests
    PROMPT
  end

  # Verify
  ruby(:verify) do
    workspace = kwarg(:workspace_path)
    errors = []

    result = `cd #{workspace} && bundle check 2>&1`
    errors << "bundle check:\n#{result}" unless $?.success?

    result = `cd #{workspace} && bin/rails db:prepare 2>&1`
    errors << "db:prepare:\n#{result}" unless $?.success?

    result = `cd #{workspace} && bin/rails runner "puts :ok" 2>&1`
    errors << "boot check:\n#{result}" unless $?.success?

    test_files = Dir.glob("#{workspace}/test/**/*_test.rb")
    if test_files.any?
      result = `cd #{workspace} && bin/rails test 2>&1`
      errors << "rails test:\n#{result}" unless $?.success?
    end

    if errors.any?
      fail!(errors.join("\n\n"))
    end

    "all checks passed"
  end

  # Commit
  cmd(:commit) do |my, revision|
    workspace = kwarg(:workspace_path)
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && git add -A && git commit -m '#{revision[:summary]}'"]
  end
end

# --- Main workflow ---

execute do
  # W1.1: Rails new
  cmd(:rails_new) do |my|
    app_name = kwarg(:app_name)
    workspace = kwarg(:workspace)
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && rails new #{app_name} --css tailwind --database sqlite3 --skip-jbuilder --skip-test-unit"]
  end

  # Save workspace path
  ruby(:set_workspace) do
    path = File.join(kwarg(:workspace), kwarg(:app_name))
    # Set as kwarg for later steps
    metadata[:workspace_path] = path
    path
  end

  # Git init (rails new does this automatically, but let's make sure)
  cmd(:git_init) do |my|
    workspace = ruby!(:set_workspace).value
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && git add -A && git commit -m 'Initial Rails app' --allow-empty"]
  end

  # W1.3: Plan — LLM generates the list of revisions
  chat(:plan) do
    <<~PROMPT
      You are a Rails application planner. Based on the description, generate an implementation plan
      as a list of steps (revisions). Every step should be atomic and testable.

      Application description: #{kwarg(:prompt)}

      Respond as a JSON array of objects with fields:
      - "summary": short step description (for git commit message)
      - "prompt": detailed description of what to do in this step

      Rules:
      - Step 1: models and migrations (foundations)
      - Step 2: controllers and routing
      - Step 3: views (Tailwind + Hotwire)
      - Step 4: tests
      - Max 4-5 steps for a simple app
      - Every step must yield a working app (do not leave broken state)

      Respond ONLY with JSON, no markdown code blocks.
    PROMPT
  end

  # Parse plan
  ruby(:parse_plan) do
    require "json"
    raw = chat!(:plan).text
    # Extract JSON from the response (in case the LLM added text around it)
    json_match = raw.match(/\[.*\]/m)
    fail!("Plan does not contain a JSON array") unless json_match
    JSON.parse(json_match[0], symbolize_names: true)
  end

  # W1.5: Execute revisions
  map(:build, run: :execute_revision) do |my|
    my.items = ruby!(:parse_plan).value
  end

  # Report
  ruby(:report) do
    workspace = ruby!(:set_workspace).value
    log = `cd #{workspace} && git log --oneline 2>&1`
    puts "\n=== Generation completed ==="
    puts "Workspace: #{workspace}"
    puts "Git log:\n#{log}"
    { workspace: workspace, status: :completed }
  end
end
