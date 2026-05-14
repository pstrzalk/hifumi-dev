# frozen_string_literal: true

# Builds the W2.1 implementation prompt fed to the `claude` CLI for a single
# revision. Extracted from revision_workflow.rb's inline DSL block so the
# prompt-shape is unit-testable in isolation — the Roast block now just
# threads kwargs in.
#
# Sections, in order:
#   1. Task (revision_prompt)
#   2. Summary (revision_summary, the git commit message)
#   3. Stack inventory + anti-reflexes — what's in the skeleton Gemfile and
#      which common LLM training-data reflexes to avoid. Prevents the class
#      of failure where the agent writes `before_action :authenticate_user!`
#      because Devise is what its training data reaches for, even though
#      Devise isn't installed.
#   4. Current application state (manifest assembled from docs/*.md)
#   5. Workspace snapshot (controllers/, models/, routes.rb, application_controller.rb)
#   6. Context from previous revisions (docs/revision_notes.md)
#   7. Rules
module RevisionPrompt
  def self.build(workspace:, revision_prompt:, revision_summary:)
    docs_dir = File.join(workspace, "docs")

    parts = []
    parts << "## Task\n\n#{revision_prompt}"
    parts << "## Summary (git commit message)\n\n#{revision_summary}"
    parts << stack_inventory_section

    manifest = build_manifest(docs_dir)
    parts << "## Current application state (manifest)\n\n#{manifest}" unless manifest.empty?

    snapshot = build_snapshot(workspace)
    parts << "## Workspace snapshot\n\n#{snapshot}" unless snapshot.empty?

    revision_notes = read_revision_notes(docs_dir)
    parts << "## Context from previous revisions\n\n#{revision_notes}" unless revision_notes.empty?

    parts << rules_section(workspace)

    parts.join("\n\n")
  end

  def self.stack_inventory_section
    <<~STACK.chomp
      ## Stack already installed in this app

      Already available — no Gemfile change needed:
      - Rails 8.1, Propshaft (no Sprockets), Importmap (no jsbundling)
      - Turbo + Stimulus
      - Tailwind (tailwindcss-rails)
      - SQLite, Solid Queue (jobs), Solid Cache, Solid Cable
      - bcrypt is COMMENTED OUT in Gemfile — uncomment + `bundle install` if you need `has_secure_password`

      Prefer Rails built-ins over gem reflexes:
      - Auth → `has_secure_password` + sessions, NOT Devise
      - Authz → `before_action` checks in controllers, NOT Pundit/CanCanCan
      - Background jobs → Solid Queue, NOT Sidekiq/Resque
      - JS bundling → Importmap, NOT jsbundling-rails/webpack/esbuild
      - Pagination, slugs, soft-delete: write them yourself

      If you do need an extra gem, add it to Gemfile + run `bundle install` + run any install generator BEFORE using it. The verify step will catch a missing constant otherwise.
    STACK
  end

  def self.build_manifest(docs_dir)
    Dir.glob("#{docs_dir}/{architecture,conventions,domain,frontend}.md")
       .map { |f| "### #{File.basename(f)}\n\n#{File.read(f)}" }
       .join("\n\n")
  end

  def self.build_snapshot(workspace)
    snapshot_parts = []
    %w[app/controllers app/models].each do |dir|
      files = Dir.glob("#{workspace}/#{dir}/**/*.rb").sort.map { |f| f.sub("#{workspace}/", "") }
      snapshot_parts << "**#{dir}/** — #{files.empty? ? '(empty)' : files.join(', ')}"
    end
    routes_path = File.join(workspace, "config/routes.rb")
    if File.exist?(routes_path)
      snapshot_parts << "**config/routes.rb**\n```ruby\n#{File.read(routes_path)}```"
    end
    app_ctrl_path = File.join(workspace, "app/controllers/application_controller.rb")
    if File.exist?(app_ctrl_path)
      snapshot_parts << "**app/controllers/application_controller.rb**\n```ruby\n#{File.read(app_ctrl_path)}```"
    end
    snapshot_parts.join("\n\n")
  end

  def self.read_revision_notes(docs_dir)
    notes_path = File.join(docs_dir, "revision_notes.md")
    File.exist?(notes_path) ? File.read(notes_path) : ""
  end

  def self.rules_section(workspace)
    <<~RULES.chomp
      ## Rules
      - Rails Way: conventions, generators, built-in solutions
      - Tailwind CSS for styling
      - Follow `docs/frontend.md` (palette, fonts, density, class snippets) for every view. Don't ship default Rails scaffold markup or unstyled forms — apply the template's class snippets to buttons, inputs, cards, navs, alerts. Inline hex values in arbitrary-value brackets (`bg-[#00FFCC]`) are fine.
      - Hotwire (Turbo + Stimulus), no React/Vue
      - Minitest, not RSpec
      - Write tests for new functionality
      - Don't create empty directories or files that aren't needed
      - You are working in #{workspace} — all paths are relative to this directory
      - The snapshot above is current. Don't glob or list directories to discover what already exists; only read a specific file when you actually need its contents to make the change.
    RULES
  end
end
