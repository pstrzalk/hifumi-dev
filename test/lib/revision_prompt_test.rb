require "test_helper"
require "tmpdir"
require "fileutils"
require Rails.root.join("lib/roast/revision_prompt")

class RevisionPromptTest < ActiveSupport::TestCase
  setup do
    @workspace = Dir.mktmpdir("revision-prompt-test-")
  end

  teardown do
    FileUtils.remove_entry(@workspace) if File.exist?(@workspace)
  end

  # ---- top-level structure ----

  test "includes the task and summary kwargs verbatim" do
    out = RevisionPrompt.build(
      workspace: @workspace,
      revision_prompt: "Add a Todo model with title, body, done flag.",
      revision_summary: "feat: todo model"
    )

    assert_includes out, "## Task\n\nAdd a Todo model with title, body, done flag."
    assert_includes out, "## Summary (git commit message)\n\nfeat: todo model"
  end

  test "embeds workspace path in the rules section" do
    out = build_minimal(workspace: @workspace)
    assert_includes out, "You are working in #{@workspace}"
  end

  # ---- stack inventory: positive markers ----

  test "stack inventory names Rails 8.1 + Propshaft + Importmap" do
    out = build_minimal
    assert_includes out, "Rails 8.1"
    assert_includes out, "Propshaft"
    assert_includes out, "Importmap"
  end

  test "stack inventory names Turbo + Stimulus + Tailwind" do
    out = build_minimal
    assert_includes out, "Turbo + Stimulus"
    assert_includes out, "Tailwind"
  end

  test "stack inventory names Solid Queue + Solid Cache + Solid Cable" do
    out = build_minimal
    assert_includes out, "Solid Queue"
    assert_includes out, "Solid Cache"
    assert_includes out, "Solid Cable"
  end

  test "stack inventory flags bcrypt as commented out + needing has_secure_password" do
    out = build_minimal
    assert_includes out, "bcrypt is COMMENTED OUT"
    assert_includes out, "has_secure_password"
  end

  # ---- anti-reflex markers (one per gem the agent reflexively reaches for) ----

  test "anti-reflex: NOT Devise" do
    out = build_minimal
    assert_includes out, "NOT Devise"
  end

  test "anti-reflex: NOT Pundit/CanCanCan" do
    out = build_minimal
    assert_includes out, "NOT Pundit/CanCanCan"
  end

  test "anti-reflex: NOT Sidekiq" do
    out = build_minimal
    assert_includes out, "NOT Sidekiq/Resque"
  end

  test "anti-reflex: NOT jsbundling/webpack" do
    out = build_minimal
    assert_includes out, "NOT jsbundling-rails/webpack/esbuild"
  end

test "anti-reflex: NOT RSpec/FactoryBot" do
  out = build_minimal
  assert_includes out, "NOT RSpec/FactoryBot"
end

  test "documents the extra-gem escape hatch (Gemfile + bundle install + generator)" do
    out = build_minimal
    assert_includes out, "add it to Gemfile"
    assert_includes out, "bundle install"
    assert_includes out, "install generator"
  end

  # ---- conditional sections: manifest ----

  test "manifest section omitted when docs/ is empty" do
    out = build_minimal(workspace: @workspace)
    refute_includes out, "## Current application state (manifest)"
  end

  test "manifest section included when docs/*.md present, with each filename heading" do
    docs = File.join(@workspace, "docs")
    FileUtils.mkdir_p(docs)
    File.write(File.join(docs, "architecture.md"), "# Architecture\n\nRails app with a Todo model.\n")
    File.write(File.join(docs, "conventions.md"), "# Conventions\n\nMinitest. Tailwind.\n")
    File.write(File.join(docs, "domain.md"), "# Domain\n\nTodo: a task to complete.\n")
    File.write(File.join(docs, "frontend.md"), "# Frontend\n\nBeige palette.\n")

    out = build_minimal(workspace: @workspace)

    assert_includes out, "## Current application state (manifest)"
    assert_includes out, "### architecture.md"
    assert_includes out, "### conventions.md"
    assert_includes out, "### domain.md"
    assert_includes out, "### frontend.md"
    assert_includes out, "Rails app with a Todo model."
    assert_includes out, "Beige palette."
  end

  # ---- conditional sections: workspace snapshot ----

  test "snapshot section reports '(empty)' for missing controllers/models" do
    out = build_minimal(workspace: @workspace)
    assert_includes out, "**app/controllers/** — (empty)"
    assert_includes out, "**app/models/** — (empty)"
  end

  test "snapshot lists controllers/models that exist" do
    FileUtils.mkdir_p(File.join(@workspace, "app/controllers"))
    FileUtils.mkdir_p(File.join(@workspace, "app/models"))
    File.write(File.join(@workspace, "app/controllers/todos_controller.rb"), "class TodosController < ApplicationController; end")
    File.write(File.join(@workspace, "app/models/todo.rb"), "class Todo < ApplicationRecord; end")

    out = build_minimal(workspace: @workspace)

    assert_includes out, "app/controllers/todos_controller.rb"
    assert_includes out, "app/models/todo.rb"
  end

  test "snapshot inlines routes.rb when present" do
    FileUtils.mkdir_p(File.join(@workspace, "config"))
    File.write(File.join(@workspace, "config/routes.rb"), "Rails.application.routes.draw do\n  resources :todos\nend\n")

    out = build_minimal(workspace: @workspace)

    assert_includes out, "**config/routes.rb**"
    assert_includes out, "resources :todos"
  end

  test "snapshot inlines application_controller.rb when present" do
    FileUtils.mkdir_p(File.join(@workspace, "app/controllers"))
    File.write(
      File.join(@workspace, "app/controllers/application_controller.rb"),
      "class ApplicationController < ActionController::Base\nend\n"
    )

    out = build_minimal(workspace: @workspace)

    assert_includes out, "**app/controllers/application_controller.rb**"
    assert_includes out, "class ApplicationController < ActionController::Base"
  end

  # ---- conditional section: revision notes ----

  test "revision notes section omitted when docs/revision_notes.md missing" do
    out = build_minimal(workspace: @workspace)
    refute_includes out, "## Context from previous revisions"
  end

  test "revision notes section included when docs/revision_notes.md present" do
    docs = File.join(@workspace, "docs")
    FileUtils.mkdir_p(docs)
    File.write(File.join(docs, "revision_notes.md"), "# Revision notes\n\n## Rev 1\n\nAdded Todo.\n")

    out = build_minimal(workspace: @workspace)

    assert_includes out, "## Context from previous revisions"
    assert_includes out, "Added Todo."
  end

# ---- rules: the code agent must not follow a task that names spec/ ----
# Production project 40: the plan named spec/ files, the agent said out loud
# that "Minitest, not RSpec" conflicted with the task, and followed the task.
# The rule now says which one wins and what to do instead.

test "rules: a task naming spec/ is translated to test/, not followed" do
  out = build_minimal
  assert_includes out, "Tests are Minitest under `test/`, run with `bin/rails test`"
  assert_includes out, "write the equivalent Minitest tests under `test/` instead"
  assert_includes out, "the task's wording does not override this"
end

test "rules: no test gem may be added" do
  out = build_minimal
  assert_includes out, "Do not add rspec-rails or any other test gem"
end

  # ---- ordering: stack inventory precedes manifest precedes rules ----

  test "section order: Task → Summary → Stack → Photos → (Manifest) → (Snapshot) → (Notes) → Rules" do
    docs = File.join(@workspace, "docs")
    FileUtils.mkdir_p(docs)
    File.write(File.join(docs, "architecture.md"), "manifest content")
    File.write(File.join(docs, "revision_notes.md"), "notes content")

    out = build_minimal(workspace: @workspace)

    positions = {
      task: out.index("## Task"),
      summary: out.index("## Summary"),
      stack: out.index("## Stack already installed"),
      photos: out.index("## Photos available"),
      manifest: out.index("## Current application state"),
      snapshot: out.index("## Workspace snapshot"),
      notes: out.index("## Context from previous revisions"),
      rules: out.index("## Rules")
    }

    assert(positions.values.all?, "every section should be present in fixture, got #{positions.inspect}")
    assert_operator positions[:task],     :<, positions[:summary]
    assert_operator positions[:summary],  :<, positions[:stack]
    assert_operator positions[:stack],    :<, positions[:photos]
    assert_operator positions[:photos],   :<, positions[:manifest]
    assert_operator positions[:manifest], :<, positions[:snapshot]
    assert_operator positions[:snapshot], :<, positions[:notes]
    assert_operator positions[:notes],    :<, positions[:rules]
  end

  # ---- the subprocess load path ----

  # RevisionPrompt renders Photos.prompt_section, and both are loaded by
  # lib/roast/revision_workflow.rb under `bundle exec roast` — no environment.rb,
  # no Zeitwerk, no Rails constant. In this test process Rails is always loaded,
  # so the only way to catch a Rails dependency creeping into either file is to
  # require them the way the subprocess does, in a bare Ruby process.
  test "the workflow's require chain resolves RevisionPrompt and Photos with no Rails" do
    script = <<~RUBY
      raise "Rails is defined" if defined?(Rails)
      require #{Rails.root.join('lib/roast/revision_prompt').to_s.inspect}
      require #{Rails.root.join('lib/photos').to_s.inspect}
      out = RevisionPrompt.build(workspace: Dir.mktmpdir, revision_prompt: "p", revision_summary: "s")
      raise "no photo section" unless out.include?("## Photos available")
      print "ok"
    RUBY

    out = nil
    Bundler.with_unbundled_env do
      out = `cd #{Shellwords.escape(Rails.root.to_s)} && bundle exec ruby -rtmpdir -e #{Shellwords.escape(script)} 2>&1`
    end

    assert_predicate $?, :success?, "bare-Ruby load failed:\n#{out}"
    assert_equal "ok", out
  end

  test "the photo section reflects PHOTOS_BASE_URL in the subprocess" do
    script = <<~RUBY
      require #{Rails.root.join('lib/photos').to_s.inspect}
      print Photos.prompt_section
    RUBY

    out = nil
    Bundler.with_unbundled_env do
      out = `cd #{Shellwords.escape(Rails.root.to_s)} && PHOTOS_BASE_URL=https://hifumi.dev bundle exec ruby -e #{Shellwords.escape(script)} 2>&1`
    end

    assert_predicate $?, :success?, "bare-Ruby load failed:\n#{out}"
    assert_includes out, "https://hifumi.dev/photos/"
  end

  # ---- rules: the agent's throwaway web server ----
  # The agent boots one unasked (nothing in the prompt requests it) and frees
  # the port first with `lsof -ti:3000 | xargs kill` — which in dev is the
  # generator's own puma. These pin both halves of the rule that stops it.

  test "rules name the default port when HIFUMI_AGENT_WEB_SERVER_PORT is unset" do
    out = with_env("HIFUMI_AGENT_WEB_SERVER_PORT" => nil) { build_minimal }

    assert_includes out, "bin/rails server -p 40000"
  end

  test "rules name the operator's port when HIFUMI_AGENT_WEB_SERVER_PORT is set" do
    out = with_env("HIFUMI_AGENT_WEB_SERVER_PORT" => "41234") { build_minimal }

    assert_includes out, "bin/rails server -p 41234"
    refute_includes out, "bin/rails server -p 40000"
  end

  test "web_server_port falls back to the default when the env var is blank" do
    with_env("HIFUMI_AGENT_WEB_SERVER_PORT" => "  ") do
      assert_equal RevisionPrompt::DEFAULT_WEB_SERVER_PORT, RevisionPrompt.web_server_port
    end
  end

  test "rules forbid killing a process the agent did not start" do
    out = build_minimal

    assert_includes out, "Never kill a process you did not start"
    assert_includes out, "lsof -ti:<port> | xargs kill"
    assert_includes out, "pkill -f puma"
  end

  test "rules point at the verifier so a server is not the way to check a page" do
    out = build_minimal

    assert_includes out, "requests every static GET page"
    assert_includes out, "test/integration/"
  end

  private

  def build_minimal(workspace: @workspace, revision_prompt: "Do a thing.", revision_summary: "feat: thing")
    RevisionPrompt.build(
      workspace: workspace,
      revision_prompt: revision_prompt,
      revision_summary: revision_summary
    )
  end
end
