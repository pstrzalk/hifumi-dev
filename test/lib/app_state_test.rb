require "test_helper"
require "tmpdir"
require "fileutils"

class AppStateTest < ActiveSupport::TestCase
  SKELETON_GEMFILE = Rails.root.join("lib/preview/skeleton/Gemfile")

  setup do
    @workspace = Dir.mktmpdir("app-state-test-")
  end

  teardown do
    FileUtils.remove_entry(@workspace) if File.exist?(@workspace)
  end

  # ---- build: gate on Gemfile ----

  test "build returns nil when the workspace has no Gemfile" do
    write("config/routes.rb", "Rails.application.routes.draw do\nend\n")
    assert_nil AppState.build(workspace: @workspace)
  end

  test "build returns nil when the workspace directory does not exist" do
    assert_nil AppState.build(workspace: File.join(@workspace, "missing"))
  end

  # ---- gems ----

  test "gems: baseline-only Gemfile is described as the default Gemfile" do
    copy_skeleton_gemfile
    out = AppState.gems_section(@workspace)

    assert_includes out, "### Gems"
    assert_includes out, "Standard Rails #{AppState.rails_version} application with Tailwind and Hotwire, on the default Gemfile."
  end

  test "gems: the Rails version comes from the skeleton Gemfile, so a Rails bump cannot leave it stale" do
    assert_match(/\A\d+\.\d+\z/, AppState.rails_version)
    assert_includes File.read(SKELETON_GEMFILE), "gem \"rails\", \"~> #{AppState.rails_version}."
  end

  test "gems: extras are listed after the default Gemfile, skeleton gems are not" do
    copy_skeleton_gemfile(extra: "gem \"devise\"\ngem 'roo', \"~> 2.10\"\n")
    out = AppState.gems_section(@workspace)

    assert_includes out, "with these gems added on top of the default Gemfile: devise, roo."
    %w[rails propshaft sqlite3 puma importmap-rails turbo-rails stimulus-rails tailwindcss-rails
       solid_cache solid_queue solid_cable bootsnap thruster image_processing].each do |skeleton_gem|
      refute_includes out, skeleton_gem, "skeleton gem #{skeleton_gem} must not be listed as an extra"
    end
  end

  test "gems: the commented-out bcrypt line in the skeleton is not a skeleton gem, so uncommenting it surfaces it" do
    copy_skeleton_gemfile(extra: "gem \"bcrypt\", \"~> 3.1.7\"\n")
    assert_includes AppState.gems_section(@workspace), "default Gemfile: bcrypt."
  end

  test "gems: never asserts an absence" do
    copy_skeleton_gemfile
    baseline = AppState.gems_section(@workspace)
    copy_skeleton_gemfile(extra: "gem \"devise\"\n")
    with_extra = AppState.gems_section(@workspace)

    [ baseline, with_extra ].each do |out|
      refute_match(/\b(no|not|without|absent|missing)\b/i, out, "gems section must state only what is there")
    end
  end

  test "gems: section omitted when Gemfile is missing" do
    assert_nil AppState.gems_section(@workspace)
  end

  # ---- schema ----

  test "schema: present -> one line per table with column (type) pairs, no indexes or foreign keys" do
    write("db/schema.rb", <<~RUBY)
      # This file is auto-generated from the current state of the database.
      ActiveRecord::Schema[8.1].define(version: 2026_04_29_224254) do
        create_table "tasks", force: :cascade do |t|
          t.string "title", null: false
          t.integer "user_id", null: false
          t.datetime "created_at", null: false
          t.index ["user_id"], name: "index_tasks_on_user_id"
        end

        create_table "users", force: :cascade do |t|
          t.string "email"
        end

        add_foreign_key "tasks", "users"
      end
    RUBY

    out = AppState.schema_section(@workspace)

    assert_includes out, "### Database tables"
    assert_includes out, "- tasks: title (string), user_id (integer), created_at (datetime)\n"
    assert_includes out, "- users: email (string)"
    refute_includes out, "index_tasks_on_user_id"
    refute_includes out, "add_foreign_key"
    refute_includes out, "ActiveRecord::Schema"
  end

  test "schema: a column line before any create_table is ignored rather than raising" do
    write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 1) do\n  t.string \"stray\"\n  create_table \"tasks\" do |t|\n    t.string \"title\"\n  end\nend\n")
    assert_includes AppState.schema_section(@workspace), "- tasks: title (string)"
  end

  test "schema: present but without tables -> section omitted" do
    write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 0) do\nend\n")
    assert_nil AppState.schema_section(@workspace)
  end

  test "schema absent, db/migrate empty -> says no migrations exist yet" do
    FileUtils.mkdir_p(File.join(@workspace, "db/migrate"))
    out = AppState.schema_section(@workspace)

    assert_includes out, "### Database"
    assert_includes out, "No migrations exist yet"
  end

  test "schema absent, db/migrate populated -> lists migrations and does not claim the app has no tables" do
    write("db/migrate/20260429224200_create_users.rb", "class CreateUsers < ActiveRecord::Migration[8.1]; end\n")
    write("db/migrate/20260429224254_create_tasks.rb", "class CreateTasks < ActiveRecord::Migration[8.1]; end\n")

    out = AppState.schema_section(@workspace)

    assert_includes out, "- db/migrate/20260429224200_create_users.rb\n- db/migrate/20260429224254_create_tasks.rb"
    assert_includes out, "No `db/schema.rb` has been written yet"
    refute_includes out, "no tables"
    refute_includes out, "No migrations exist yet"
  end

  # ---- routes ----

  test "routes: absent -> section omitted" do
    assert_nil AppState.routes_section(@workspace)
  end

  test "routes: present -> fenced and verbatim" do
    routes = "Rails.application.routes.draw do\n  resources :standups, only: [:index, :create]\n  root \"standups#index\"\nend\n"
    write("config/routes.rb", routes)

    out = AppState.routes_section(@workspace)

    assert_equal "### Routes (config/routes.rb)\n\n```ruby\n#{routes.rstrip}\n```", out
  end

  # ---- files ----

  test "files: empty app/ -> section omitted" do
    FileUtils.mkdir_p(File.join(@workspace, "app/models"))
    assert_nil AppState.files_section(@workspace)
  end

  test "files: lists app/concerns/ alongside controllers, models, views and JS" do
    write("app/concerns/role_authorizable.rb", "module RoleAuthorizable; end\n")
    write("app/controllers/standups_controller.rb", "class StandupsController; end\n")
    write("app/models/standup.rb", "class Standup; end\n")
    write("app/views/standups/index.html.erb", "<h1>Standups</h1>\n")
    write("app/javascript/controllers/hello_controller.js", "export default class {}\n")

    out = AppState.files_section(@workspace)

    assert_includes out, "### Files under app/"
    assert_includes out, "app/concerns/role_authorizable.rb"
    assert_includes out, "app/controllers/standups_controller.rb"
    assert_includes out, "app/models/standup.rb"
    assert_includes out, "app/views/standups/index.html.erb"
    assert_includes out, "app/javascript/controllers/hello_controller.js"
    refute_includes out, @workspace, "paths must be workspace-relative"
  end

  test "files: lists the two real stylesheets and excludes app/assets/builds/" do
    write("app/assets/stylesheets/application.css", "/* Rails */\n")
    write("app/assets/tailwind/application.css", "@import \"tailwindcss\";\n")
    write("app/assets/builds/tailwind.css", "/* compiled */\n")

    out = AppState.files_section(@workspace)

    assert_includes out, "app/assets/stylesheets/application.css"
    assert_includes out, "app/assets/tailwind/application.css"
    refute_includes out, "app/assets/builds/tailwind.css"
  end

  test "files: listing is sorted by full path, not glob order, so the payload is deterministic" do
    write("app/foo/a.css", "")
    write("app/foo/y.rb", "")
    write("app/foo-bar/x.rb", "")

    assert_equal "### Files under app/\n\napp/foo-bar/x.rb\napp/foo/a.css\napp/foo/y.rb", AppState.files_section(@workspace)
  end

  test "files: ignores non-source files under app/" do
    write("app/assets/images/logo.png", "PNG")
    write("app/models/standup.rb", "class Standup; end\n")

    out = AppState.files_section(@workspace)

    assert_includes out, "app/models/standup.rb"
    refute_includes out, "logo.png"
  end

  # ---- docs ----

  test "docs: all placeholders -> section omitted" do
    write_placeholder_docs
    assert_nil AppState.docs_section(@workspace)
  end

  test "docs: absent docs/ -> section omitted" do
    assert_nil AppState.docs_section(@workspace)
  end

  test "docs: a real architecture.md next to a placeholder domain.md -> only the former appears" do
    write_placeholder_docs
    write("docs/architecture.md", "# Architecture\n\nStandup model, StandupsController.\n")

    out = AppState.docs_section(@workspace)

    assert_includes out, "### docs/architecture.md\n\n````markdown\n# Architecture\n\nStandup model, StandupsController."
    refute_includes out, "### docs/domain.md"
    refute_includes out, "### docs/conventions.md"
    refute_includes out, AppState::PLACEHOLDER
  end

  test "docs: a populated doc that still carries the baseline placeholder line is kept" do
    write("docs/domain.md", "# Domain\n\n#{AppState::PLACEHOLDER}\n\n## Standup\n\nOne row per daily standup.\n")

    out = AppState.docs_section(@workspace)

    assert_includes out, "### docs/domain.md"
    assert_includes out, "One row per daily standup."
  end

  test "docs: frontend.md alone appears" do
    write("docs/frontend.md", "# Frontend\n\nOffice template. Primary #0052CC.\n")

    out = AppState.docs_section(@workspace)

    assert_includes out, "### docs/frontend.md\n\n````markdown\n# Frontend\n\nOffice template. Primary #0052CC."
  end

  test "docs: revision_notes.md is never read" do
    write("docs/revision_notes.md", "# Revision notes\n\nrationale rationale\n")
    write("docs/frontend.md", "# Frontend\n")

    out = AppState.docs_section(@workspace)

    refute_includes out, "revision_notes"
    refute_includes out, "rationale"
  end

  # ---- docs cap ----

  test "docs cap: a file over the cap is truncated with a marker naming that file" do
    write("docs/architecture.md", "a" * (AppState::DOC_FILE_CAP + 1))

    out = AppState.docs_section(@workspace)

    assert_includes out, "[... docs/architecture.md truncated at #{AppState::DOC_FILE_CAP} chars ...]"
    assert_includes out, "a" * AppState::DOC_FILE_CAP
    refute_includes out, "a" * (AppState::DOC_FILE_CAP + 1)
  end

  test "docs cap: a file exactly at the cap is untouched" do
    write("docs/architecture.md", "a" * AppState::DOC_FILE_CAP)

    out = AppState.docs_section(@workspace)

    refute_includes out, "truncated"
    assert_includes out, "a" * AppState::DOC_FILE_CAP
  end

  test "docs cap is per file: an oversized architecture.md leaves frontend.md intact" do
    frontend = "# Frontend\n\n" + ("palette #0052CC, #DE350B\n" * 40)
    write("docs/architecture.md", "a" * (AppState::DOC_FILE_CAP + 500))
    write("docs/frontend.md", frontend)

    out = AppState.docs_section(@workspace)

    assert_includes out, "[... docs/architecture.md truncated at"
    refute_includes out, "[... docs/frontend.md truncated at"
    assert_includes out, "### docs/frontend.md\n\n````markdown\n#{frontend.rstrip}"
  end

  test "docs cap is per file: two oversized files each carry their own marker" do
    write("docs/architecture.md", "a" * (AppState::DOC_FILE_CAP + 1))
    write("docs/domain.md", "d" * (AppState::DOC_FILE_CAP + 1))

    out = AppState.docs_section(@workspace)

    assert_includes out, "[... docs/architecture.md truncated at"
    assert_includes out, "[... docs/domain.md truncated at"
  end

  test "docs: bodies are fenced with four backticks, so a code block inside a doc cannot close the fence" do
    write("docs/conventions.md", "# Conventions\n\n## Gems\n\n```ruby\ngem \"roo\"\n```\n")

    out = AppState.docs_section(@workspace)

    assert_equal "### docs/conventions.md\n\n````markdown\n# Conventions\n\n## Gems\n\n```ruby\ngem \"roo\"\n```\n````", out
  end

  test "docs cap counts characters, so a multi-byte boundary stays valid UTF-8" do
    # 7999 ASCII chars, then an em dash straddling the 8000th character. A byte
    # slice would cut inside the 3-byte em dash; a character slice cannot.
    write("docs/architecture.md", ("a" * (AppState::DOC_FILE_CAP - 1)) + "—" + ("b" * 100))

    out = AppState.docs_section(@workspace)

    assert_predicate out, :valid_encoding?
    assert_includes out, "a—\n[... docs/architecture.md truncated at"
    refute_includes out, "b"
  end

  # ---- reads: the workspace is agent-written ----

  test "reads: invalid UTF-8 in any workspace file is scrubbed, never raised" do
    # One stray byte in each file the module reads. Before read_workspace_file,
    # scan (Gemfile), the per-line regex (schema) and rstrip (routes, docs) each
    # raised on it and the tool reported a planner failure for every request after.
    write_bytes("Gemfile", (File.read(SKELETON_GEMFILE) + "gem \"roo\" # caf\xE9\n").b)
    write_bytes("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"standups\" do |t|\n    t.string \"name\" # caf\xE9\n  end\nend\n".b)
    write_bytes("config/routes.rb", "Rails.application.routes.draw do\n  resources :standups # caf\xE9\nend\n".b)
    write_bytes("docs/architecture.md", "# Architecture\n\nStandup model. caf\xE9\n".b)

    out = nil
    assert_nothing_raised { out = AppState.build(workspace: @workspace) }

    assert_predicate out, :valid_encoding?
    assert_includes out, "default Gemfile: roo."
    assert_includes out, "- standups: name (string)"
    assert_includes out, "resources :standups # caf�"
    assert_includes out, "### docs/architecture.md\n\n````markdown\n# Architecture\n\nStandup model. caf�"
  end

  test "reads: a symlink that resolves outside the workspace is treated as absent" do
    outside = Dir.mktmpdir("app-state-outside-")
    File.write(File.join(outside, "domain.md"), "# Domain\n\nOTHER TENANT SECRET\n")
    File.write(File.join(outside, "routes.rb"), "Rails.application.routes.draw do\n  # OTHER TENANT SECRET\nend\n")
    copy_skeleton_gemfile
    FileUtils.mkdir_p(File.join(@workspace, "docs"))
    FileUtils.mkdir_p(File.join(@workspace, "config"))
    FileUtils.ln_s(File.join(outside, "domain.md"), File.join(@workspace, "docs/domain.md"))
    FileUtils.ln_s(File.join(outside, "routes.rb"), File.join(@workspace, "config/routes.rb"))

    out = AppState.build(workspace: @workspace)

    refute_includes out, "OTHER TENANT SECRET"
    refute_includes out, "### docs/domain.md"
    refute_includes out, "### Routes"
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  test "reads: a symlink that stays inside the workspace is read" do
    write("notes/architecture.md", "# Architecture\n\nStandup model, linked in.\n")
    FileUtils.mkdir_p(File.join(@workspace, "docs"))
    FileUtils.ln_s("../notes/architecture.md", File.join(@workspace, "docs/architecture.md"))

    assert_includes AppState.docs_section(@workspace), "### docs/architecture.md\n\n````markdown\n# Architecture\n\nStandup model, linked in."
  end

  test "the W2.6 docs-writer prompt quotes DOC_FILE_CAP — the two are maintained together" do
    assert_includes File.read(Rails.root.join("lib/roast/revision_workflow.rb")), "under #{AppState::DOC_FILE_CAP} characters"
  end

  test "build returns nil when no section has anything to say" do
    outside = Dir.mktmpdir("app-state-outside-")
    File.write(File.join(outside, "Gemfile"), "gem \"rails\"\n")
    FileUtils.ln_s(File.join(outside, "Gemfile"), File.join(@workspace, "Gemfile"))
    write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 0) do\nend\n")

    assert_nil AppState.build(workspace: @workspace)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  # ---- build: assembly ----

  test "build joins the preamble and every present section in order" do
    write_full_workspace

    out = AppState.build(workspace: @workspace)

    positions = {
      preamble: out.index("## Current application state"),
      gems: out.index("### Gems"),
      schema: out.index("### Database tables"),
      routes: out.index("### Routes (config/routes.rb)"),
      files: out.index("### Files under app/"),
      docs: out.index("### docs/architecture.md")
    }

    assert(positions.values.all?, "every section should be present in fixture, got #{positions.inspect}")
    assert_operator positions[:preamble], :<, positions[:gems]
    assert_operator positions[:gems],     :<, positions[:schema]
    assert_operator positions[:schema],   :<, positions[:routes]
    assert_operator positions[:routes],   :<, positions[:files]
    assert_operator positions[:files],    :<, positions[:docs]
  end

  test "build's preamble marks the lists authoritative and docs/ as a lagging summary" do
    write_full_workspace

    out = AppState.build(workspace: @workspace)

    assert_match(/The gems, tables, routes and file list are\s+authoritative\./, out)
    assert_includes out, "prefer the lists above it on any conflict."
  end

  test "build omits absent sections without leaving gaps" do
    copy_skeleton_gemfile

    out = AppState.build(workspace: @workspace)

    assert_includes out, "### Gems"
    assert_includes out, "### Database\n\nNo migrations exist yet"
    refute_includes out, "### Routes"
    refute_includes out, "### Files under app/"
    refute_includes out, "### docs/"
    refute_match(/\n{3,}/, out, "sections are joined by exactly one blank line")
  end

  private

  def write(relative_path, content)
    path = File.join(@workspace, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # File.write transcodes to the external encoding; binwrite keeps a stray byte a stray byte.
  def write_bytes(relative_path, bytes)
    path = File.join(@workspace, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, bytes)
  end

  def copy_skeleton_gemfile(extra: "")
    write("Gemfile", File.read(SKELETON_GEMFILE) + extra)
  end

  def write_placeholder_docs
    %w[architecture conventions domain].each do |name|
      write("docs/#{name}.md", "# #{name.capitalize}\n\n#{AppState::PLACEHOLDER}\n")
    end
    write("docs/revision_notes.md", "# Revision notes\n\n")
  end

  def write_full_workspace
    copy_skeleton_gemfile
    write("db/schema.rb", "ActiveRecord::Schema[8.1].define(version: 1) do\n  create_table \"standups\" do |t|\n    t.string \"name\"\n  end\nend\n")
    write("config/routes.rb", "Rails.application.routes.draw do\n  resources :standups, only: [:index, :create]\nend\n")
    write("app/models/standup.rb", "class Standup < ApplicationRecord; end\n")
    write_placeholder_docs
    write("docs/architecture.md", "# Architecture\n\nStandup model.\n")
    write("docs/frontend.md", "# Frontend\n\nOffice template.\n")
  end
end
