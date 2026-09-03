# frozen_string_literal: true

# Describes a generated application to the modification planner
# (PlanApplicationModification::AdHocLLM), which otherwise plans against nothing
# but the user's sentence and invents file paths, columns and CSS variables.
#
# Deliberately NOT RevisionPrompt: that builds the *implementer's* prompt, globs
# only app/controllers + app/models (missing e.g. app/concerns/), and carries no
# schema or Gemfile diff. The two consumers want different things; the 4-line
# docs glob is duplicated on purpose.
#
# Sections, in order: Gems → Database tables → Routes → Files under app/ → docs/.
# The first four are read fresh and authoritative; docs/ is prose the W2.6 agent
# rewrites after each revision and can lag (measured: it omits real models in 3
# of 23 populated workspaces, and never invents absent ones).
module AppState
  DOC_FILES = %w[architecture.md conventions.md domain.md frontend.md].freeze

  # ExecuteInstructionJob#init_docs_baseline scaffolds three of the four docs as
  # a title line plus this line (it interpolates the constant), so File.exist?
  # cannot distinguish "the docs agent ran" from "the docs dir was created".
  # frontend.md is written by Templates::Picker and is never a placeholder.
  PLACEHOLDER = "(empty — will be filled in by the first revision)"

  # Caps each docs file on its own, in characters (see docs_section). There is
  # deliberately no cap on the docs total: a body cap over the joined files would
  # evict whichever file comes last, and on the two largest workspaces that file
  # is frontend.md — the only record of the app's palette. Sized for what new
  # projects produce: templates ship frontend.md at ~2.9 KB, the docs agent has
  # grown it to 6.7 KB at most, and every file's p90 is under 6 KB. Trims 2 files
  # in 1 of 28 current workspaces (project_39). Character slice, as
  # revision_workflow.rb's diff cap.
  #
  # The W2.6 docs-writer prompt in lib/roast/revision_workflow.rb tells the docs
  # agent this budget as a literal — that file runs as a Roast subprocess outside
  # the Rails autoloader. Update both together.
  DOC_FILE_CAP = 8_000

  SECTIONS = %i[gems schema routes files docs].freeze

  PREAMBLE = <<~TEXT.chomp
    ## Current application state

    Read from the workspace just now. The gems, tables, routes and file list are
    authoritative. The prose under `docs/` is a summary rewritten after each
    revision and may lag behind them — prefer the lists above it on any conflict.
  TEXT

  def self.build(workspace:)
    # Same predicate as Project#workspace_initialized? — without an app there is
    # nothing to describe, and every section's "absent" wording would otherwise
    # assert things about an app that does not exist.
    return nil unless File.exist?(File.join(workspace, "Gemfile"))

    sections = SECTIONS.filter_map { |s| public_send(:"#{s}_section", workspace).presence }
    return nil if sections.empty?

    ([ PREAMBLE ] + sections).join("\n\n")
  end

  def self.skeleton_gems
    @skeleton_gems ||= File.read(Rails.root.join("lib/preview/skeleton/Gemfile"))
                           .scan(/^\s*gem\s+["']([^"']+)["']/).flatten.to_set.freeze
  end

  # Major.minor from the skeleton Gemfile's `gem "rails", "~> 8.1.3"` line —
  # the same file the workspace Gemfile is copied from — so a Rails bump via
  # bin/preview-regen-skeleton cannot leave this payload asserting a stale
  # version to a planner told not to hedge.
  def self.rails_version
    @rails_version ||= File.read(Rails.root.join("lib/preview/skeleton/Gemfile"))[/^gem "rails",\s*"[^\d]*(\d+\.\d+)/, 1] || "8"
  end

  # Every workspace file is read through here. The workspace is written by the
  # sandboxed codegen agent, so a plain File.read does two wrong things:
  #
  # - It follows a symlink out of the workspace. `docs/domain.md ->
  #   ../../project_41/docs/domain.md` resolves against the generator's mount,
  #   where every tenant's workspace is, and the other project's file lands in
  #   the planner prompt and in the plan shown to the user. realpath containment
  #   also catches a symlinked directory, which an lstat on the leaf would not.
  # - It returns invalid UTF-8 as-is. `rstrip` and `scan` raise on it; the
  #   tool's rescue then reports a planner failure the user is told to fix by
  #   rephrasing, and every later request on the project fails the same way.
  #   `scrub` turns the stray bytes into U+FFFD instead.
  #
  # Returns nil when the file is missing, not a regular file, or resolves
  # outside the workspace — callers treat all three as "not there".
  def self.read_workspace_file(workspace, relative)
    path = File.join(workspace, relative)
    return nil unless File.file?(path)
    return nil unless File.realpath(path).start_with?("#{File.realpath(workspace)}/")

    File.read(path, encoding: "UTF-8").scrub
  end

  # The single highest-value section: it is what lets the planner see `bcrypt`
  # (has_secure_password) on project_30 instead of assuming Devise.
  #
  # States only what IS there. No "there is no X" sentences: a Gemfile scan
  # cannot back a claim about availability (Devise pulls in bcrypt, so "no
  # bcrypt" would be false on every Devise app), and a negative in the payload
  # is a rule the prompt then has to fight later. The planner infers absence
  # from the list itself. "Default Rails 8" + Tailwind + Hotwire is the whole
  # stack framing; Propshaft/Importmap/Solid are never enumerated — they are
  # what a default install already is, and naming them invites the planner to
  # treat them as optional extras worth a revision.
  def self.gems_section(workspace)
    gemfile = read_workspace_file(workspace, "Gemfile")
    return nil unless gemfile

    extra = gemfile.scan(/^\s*gem\s+["']([^"']+)["']/).flatten
                   .reject { |g| skeleton_gems.include?(g) }
    body = "Standard Rails #{rails_version} application with Tailwind and Hotwire, "
    body +=
      if extra.empty?
        "on the default Gemfile."
      else
        "with these gems added on top of the default Gemfile: #{extra.join(', ')}."
      end
    "### Gems\n\n#{body}"
  end

  # Condensed to table + column names: indexes, foreign keys and the 12-line
  # header are noise for planning. 8431 -> 1652 bytes on project_30.
  def self.schema_section(workspace)
    schema = read_workspace_file(workspace, "db/schema.rb")
    return migrations_section(workspace) unless schema

    tables = []
    schema.each_line do |line|
      case line
      when /^\s*create_table "([^"]+)"/ then tables << +"- #{$1}: "
      when /^\s*t\.(\w+) "([^"]+)"/     then tables.last << "#{$2} (#{$1}), " unless tables.empty?
      end
    end
    return nil if tables.empty?

    "### Database tables\n\n#{tables.map { |t| t.chomp(', ') }.join("\n")}"
  end

  # db/schema.rb only appears after VerifyRevision runs `bin/rails db:prepare`,
  # so it lags the migrations. project_3 has two migrations and two models and
  # no schema.rb — asserting "this app has no tables" there would be a confident
  # falsehood in the section the preamble calls authoritative, contradicting the
  # app/models/ entries listed a few lines below it. Name the migrations instead
  # and let the planner draw its own conclusion.
  def self.migrations_section(workspace)
    migrations = Dir.glob("#{workspace}/db/migrate/*.rb").sort.map { |f| File.basename(f) }
    return "### Database\n\nNo migrations exist yet — this app has no tables." if migrations.empty?

    "### Database\n\nNo `db/schema.rb` has been written yet (it appears after the first " \
    "verified revision), so the tables are described only by the migrations on disk:\n\n" \
    "#{migrations.map { |m| "- db/migrate/#{m}" }.join("\n")}"
  end

  def self.routes_section(workspace)
    routes = read_workspace_file(workspace, "config/routes.rb")
    return nil unless routes

    "### Routes (config/routes.rb)\n\n```ruby\n#{routes.rstrip}\n```"
  end

  # Globs all of app/, not just controllers+models: project_30 put a concern at
  # app/concerns/role_authorizable.rb, which a narrower glob misses.
  #
  # `.css` is in the list because instruction #53 — the stored defect this
  # module exists to fix — invented `app/assets/stylesheets/application.tailwind.css`.
  # The two real stylesheets (app/assets/stylesheets/application.css and
  # app/assets/tailwind/application.css) match no .rb/.erb/.js glob, so without
  # `.css` the planner still cannot see the files it hallucinated over.
  # app/assets/builds/ is excluded: tailwindcss-rails compiles into it, and
  # listing generated output invites the implementer to edit a file that the
  # next build overwrites. Costs +2 paths / +75 bytes, uniform across all 28.
  def self.files_section(workspace)
    builds = "#{workspace}/app/assets/builds/"
    files = Dir.glob("#{workspace}/app/**/*.{rb,erb,js,css}").sort
               .reject { |f| f.start_with?(builds) }
               .map { |f| f.delete_prefix("#{workspace}/") }
    return nil if files.empty?

    "### Files under app/\n\n#{files.join("\n")}"
  end

  # Each body is fenced, like routes: the docs open with `# Title` and use `##`
  # subheadings, which would otherwise outrank this payload's `###` sections in
  # the markdown hierarchy — project_28's conventions.md carries a `## Gems`
  # table enumerating propshaft/importmap/solid, exactly what gems_section
  # refuses to name, and unfenced it sits a heading level above that section
  # while the preamble asks the planner to prefer the lists. Four backticks so
  # a ``` code block inside a doc cannot close the fence early.
  def self.docs_section(workspace)
    body = DOC_FILES.filter_map do |name|
      content = read_workspace_file(workspace, File.join("docs", name))
      next unless content
      next if placeholder?(content)

      "### docs/#{name}\n\n````markdown\n#{cap_doc(content.rstrip, name)}\n````"
    end.join("\n\n")
    body.presence
  end

  # The untouched baseline is a title line and the placeholder line, nothing
  # else. A doc the W2.6 agent has populated but appended to (its rules allow
  # append-only edits) may still carry the placeholder line; that doc is real
  # and must stay, so this is a whole-body test, not a substring search.
  def self.placeholder?(content)
    lines = content.lines.map(&:strip).reject(&:empty?)
    lines.length <= 2 && lines.last == PLACEHOLDER
  end

  # Characters, not bytes: byteslice can cut mid-codepoint, and the docs are
  # full of em dashes. The result is an invalid-encoding String that JSON
  # serialization rejects outright ("source sequence is illegal/malformed
  # utf-8"), which the tool's rescue would then report as a generic planner
  # failure. String#[] cannot split a character, and it is the same idiom as
  # revision_workflow.rb's diff cap — so the marker below is also literally true.
  def self.cap_doc(content, name)
    return content if content.length <= DOC_FILE_CAP

    "#{content[0, DOC_FILE_CAP]}\n[... docs/#{name} truncated at #{DOC_FILE_CAP} chars ...]"
  end
end
