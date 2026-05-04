# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# W2: Execution of a single revision — Implement → Verify → Commit
# Aligned with ../../docs/02-architecture/01-workflows-and-decisions.md (W2.1–W2.8 + W2.R remediation + W2.F failure path).
#
# Run:
#   RAILS_APP_GENERATOR_WORKSPACE=/path/to/app bundle exec roast revision_workflow.rb -- \
#     revision_id=1 \
#     revision_summary="Add Todo model" \
#     revision_prompt="Create Todo model with title, body, done. Migration + tests."
#
# Model override via ENV:
#   RAILS_APP_GENERATOR_MODEL=haiku RAILS_APP_GENERATOR_WORKSPACE=... bundle exec roast revision_workflow.rb -- ...

require "shellwords"
require_relative "verify_revision"
require_relative "auto_remediate"
require_relative "workflow_env"

# Defaults, overrides, and validation live in Roast::WorkflowEnv so they're
# unit-testable without loading the workflow file.
WORKSPACE      = Roast::WorkflowEnv.workspace
CLAUDE_MODEL   = Roast::WorkflowEnv.claude_model
DOCS_MODEL     = Roast::WorkflowEnv.docs_model
FIX_BUDGET_USD = Roast::WorkflowEnv.fix_budget_usd

# Shared state between workflow steps (Roast DSL blocks do not share `metadata`
# or instance variables). Used to pass verify errors from W2.4 verify
# to the W2.R repeat(:remediate) block.
WORKFLOW_STATE = {}

config do
  agent do
    provider :claude
    model CLAUDE_MODEL
    working_directory WORKSPACE
    skip_permissions!
    show_stats!
  end
  # update_docs is summarization, not exploration. The diff is in the prompt
  # and only the four files in docs/ may be touched.
  # - --tools restricts to Edit/Read so the agent can't Bash/Glob/Write into
  #   the rest of the workspace; prompt-level rules alone hadn't stopped it
  #   from globbing **/* and reading 9+ unrelated files in past runs.
  # - --bare was previously here to strip Claude Code's auto-memory, hooks,
  #   plugin sync, and CLAUDE.md auto-discovery (source of the malware-ish
  #   <system-reminder> blocks bloating Reads). Dropped 2026-05-04 because
  #   --bare also skips OAuth credential loading from ~/.claude/, breaking
  #   the dev claude-subscription auth ("Not logged in · Please run /login")
  #   while leaving the default-agent invocations (which don't pass --bare)
  #   working. If the system-reminder bloat returns, find a narrower flag.
  agent(:update_docs) do
    model DOCS_MODEL
    command ["claude", "--tools", "Edit,Read"]
  end
  cmd { display! }

  # When verify ultimately fails, ensure_passing's fail! must halt the
  # workflow. Without abort_on_failure!, Roast swallows fail! (cog.rb:87)
  # and the workflow keeps going — git_commit (no-op on a reset workspace),
  # update_docs (fabricates docs against the parent commit, ~$0.5/run),
  # then exits 0 so the job marks the revision :completed despite failure.
  ruby(:ensure_passing) { abort_on_failure! }

  # agent(:fix) gets a hard budget ceiling. Without a cap, a flailing fix has
  # burned ~$1.00 in a single iteration (49-turn permission chase in
  # production-run log rev 14). A flail isn't going to find an insight at
  # turn 30 it missed at turn 10 — cap deterministically. Two iterations
  # means up to 2x FIX_BUDGET_USD across the W2.R loop.
  # --bare was previously here too; dropped 2026-05-04 for the same reason
  # as agent(:update_docs) — it breaks claude OAuth credential loading.
  agent(:fix) do
    command ["claude", "--max-budget-usd", FIX_BUDGET_USD]
  end
end

# --- W2.R: Remediation scope (max 2 attempts) ---

execute(:fix_and_reverify) do
  agent(:fix) do |_, errors, idx|
    prev_attempt = WORKFLOW_STATE[:last_fix_response]
    prev_section = if idx > 0 && prev_attempt && !prev_attempt.empty?
      <<~PREV

        ## Previous attempt summary (your last response — it didn't fully fix things)

        #{prev_attempt}

      PREV
    else
      ""
    end

    <<~PROMPT
      Verification didn't pass (attempt #{idx + 1}/2).

      Errors:

      #{errors}
      #{prev_section}
      Fix exactly what's broken. Don't change the approach. If your previous attempt is shown above, build on it instead of starting from scratch — don't repeat investigation steps you already did.
    PROMPT
  end

  ruby(:reverify) do
    # Capture the agent's response so the next iteration can build on it
    # instead of starting over with `whoami / id / ls -la` from scratch.
    WORKFLOW_STATE[:last_fix_response] = (agent!(:fix).response.to_s if agent?(:fix))

    result = VerifyRevision.run(WORKSPACE)
    puts "[W2.RV] " + VerifyRevision.summary(result).gsub("\n", "\n[W2.RV] ")
    if VerifyRevision.failed?(result)
      errors = VerifyRevision.format_errors(result)
      puts "[W2.RV] --- verify errors ---"
      puts errors.lines.map { |l| "[W2.RV] #{l}" }.join
      puts "[W2.RV] --- end verify errors ---"
      fail!(errors)
    end
    VerifyRevision.summary(result)
  end

  ruby do |_, _, idx|
    break! if ruby?(:reverify)
    break! if idx >= 1
  end

  outputs do
    ruby?(:reverify) ? :succeeded : :failed
  end
end

# --- Main workflow ---

execute do
  # W2.1: Mark generating (in production: update DB)
  ruby(:log_start) do
    puts "[W2.1] Revision ##{kwarg(:revision_id)}: #{kwarg(:revision_summary)}"
    puts "[W2.1] Workspace: #{WORKSPACE}"
    puts "[W2.1] Model: #{CLAUDE_MODEL}"
  end

  # W2.2: Build prompt with app manifest + revision notes
  ruby(:build_prompt) do
    docs_dir = File.join(WORKSPACE, "docs")
    manifest = Dir.glob("#{docs_dir}/{architecture,conventions,domain,frontend}.md")
                  .map { |f| "### #{File.basename(f)}\n\n#{File.read(f)}" }
                  .join("\n\n")
    notes_path = File.join(docs_dir, "revision_notes.md")
    revision_notes = File.exist?(notes_path) ? File.read(notes_path) : ""

    # Pre-feed a structural snapshot (controllers, models, routes file,
    # application_controller content) so the agent doesn't spend turns
    # globbing / reading these on every revision. These are small and
    # deterministic; cheaper as input tokens than as tool round-trips.
    snapshot_parts = []
    %w[app/controllers app/models].each do |dir|
      files = Dir.glob("#{WORKSPACE}/#{dir}/**/*.rb").sort.map { |f| f.sub("#{WORKSPACE}/", "") }
      snapshot_parts << "**#{dir}/** — #{files.empty? ? '(empty)' : files.join(', ')}"
    end
    routes_path = File.join(WORKSPACE, "config/routes.rb")
    if File.exist?(routes_path)
      snapshot_parts << "**config/routes.rb**\n```ruby\n#{File.read(routes_path)}```"
    end
    app_ctrl_path = File.join(WORKSPACE, "app/controllers/application_controller.rb")
    if File.exist?(app_ctrl_path)
      snapshot_parts << "**app/controllers/application_controller.rb**\n```ruby\n#{File.read(app_ctrl_path)}```"
    end
    snapshot = snapshot_parts.join("\n\n")

    parts = []
    parts << "## Task\n\n#{kwarg(:revision_prompt)}"
    parts << "## Summary (git commit message)\n\n#{kwarg(:revision_summary)}"

    unless manifest.empty?
      parts << "## Current application state (manifest)\n\n#{manifest}"
    end

    parts << "## Workspace snapshot\n\n#{snapshot}" unless snapshot.empty?

    unless revision_notes.empty?
      parts << "## Context from previous revisions\n\n#{revision_notes}"
    end

    parts << <<~RULES
      ## Rules
      - Rails Way: conventions, generators, built-in solutions
      - Tailwind CSS for styling
      - Follow `docs/frontend.md` (palette, fonts, density, class snippets) for every view. Don't ship default Rails scaffold markup or unstyled forms — apply the template's class snippets to buttons, inputs, cards, navs, alerts. Inline hex values in arbitrary-value brackets (`bg-[#00FFCC]`) are fine.
      - Hotwire (Turbo + Stimulus), no React/Vue
      - Minitest, not RSpec
      - Write tests for new functionality
      - Don't create empty directories or files that aren't needed
      - You are working in #{WORKSPACE} — all paths are relative to this directory
      - The snapshot above is current. Don't glob or list directories to discover what already exists; only read a specific file when you actually need its contents to make the change.
    RULES

    parts.join("\n\n")
  end

  # W2.3: Implement — Claude CLI generates the code
  agent(:generate_code) do
    ruby!(:build_prompt).value
  end

  # W2.4: Verify
  ruby(:verify) do
    result = VerifyRevision.run(WORKSPACE)
    puts "[W2.4] " + VerifyRevision.summary(result).gsub("\n", "\n[W2.4] ")
    if VerifyRevision.failed?(result)
      errors = VerifyRevision.format_errors(result)
      puts "[W2.4] --- verify errors ---"
      puts errors.lines.map { |l| "[W2.4] #{l}" }.join
      puts "[W2.4] --- end verify errors ---"
      WORKFLOW_STATE[:verify_errors] = errors
      fail!(errors)
    end
    "all checks passed"
  end

  # W2.AR: Deterministic auto-remediation — try known recipes before burning
  # an LLM turn. Eliminates the "agent figures out it should run bundle
  # install" round-trip when verify fails on something we already know how
  # to fix. Skip if verify passed.
  ruby(:auto_remediate) do
    skip! if ruby?(:verify)

    fixes = AutoRemediate.run(WORKSPACE, WORKFLOW_STATE[:verify_errors] || "")
    if fixes.empty?
      puts "[W2.AR] No deterministic recipe matched — falling through to agent remediation"
      fail!("no auto-remediation applied")
    end

    puts "[W2.AR] Applied: #{fixes.join('; ')}"
    result = VerifyRevision.run(WORKSPACE)
    puts "[W2.AR] " + VerifyRevision.summary(result).gsub("\n", "\n[W2.AR] ")
    if VerifyRevision.failed?(result)
      errors = VerifyRevision.format_errors(result)
      puts "[W2.AR] --- verify errors ---"
      puts errors.lines.map { |l| "[W2.AR] #{l}" }.join
      puts "[W2.AR] --- end verify errors ---"
      WORKFLOW_STATE[:verify_errors] = errors
      puts "[W2.AR] Re-verify still failing — falling through to agent remediation"
      fail!(errors)
    end

    WORKFLOW_STATE[:verify_errors] = nil
    "auto-remediated: #{fixes.join('; ')}"
  end

  # W2.R: Agent remediation loop — skip if verify or auto_remediate passed
  repeat(:remediate, run: :fix_and_reverify) do
    skip! if ruby?(:verify) || ruby?(:auto_remediate)
    puts "[W2.R] Verify failed, entering remediation loop"
    WORKFLOW_STATE[:verify_errors] || "initial verification failed"
  end

  # W2.F: Failure guard — if verify and remediation fail, we don't commit
  ruby(:ensure_passing) do
    passed = ruby?(:verify) || ruby?(:auto_remediate) ||
             (ruby?(:remediate) && repeat!(:remediate).value == :succeeded)
    unless passed
      puts "[W2.F1] Verification failed after remediation — aborting without commit"
      puts "[W2.F2] Resetting uncommitted changes in workspace"
      system("cd #{Shellwords.escape(WORKSPACE)} && git reset --hard HEAD && git clean -fd")
      fail!("W2.F: revision failed, workspace reset to parent HEAD")
    end
    "ready to commit"
  end

  # W2.5: Git commit code
  cmd(:git_commit) do |my|
    summary = kwarg(:revision_summary)
    my.command = "sh"
    my.args = ["-c", "cd #{Shellwords.escape(WORKSPACE)} && git add -A && git commit -m #{Shellwords.escape(summary)}"]
  end

  # W2.6: Update app manifest + revision notes
  #
  # Runs on haiku (DOCS_MODEL). The full diff of the revision is fed into the
  # prompt up front so the agent doesn't need to glob/read the workspace to
  # figure out what changed. Earlier this step ate $0.5-$0.8/revision; now it
  # is a constrained summarization, not an exploration.
  agent(:update_docs) do
    diff_stat = `cd #{Shellwords.escape(WORKSPACE)} && git show --stat HEAD`
    diff_body = `cd #{Shellwords.escape(WORKSPACE)} && git show HEAD`
    # Cap the diff body at a generous but bounded size — large changes still
    # get a structural summary via stat, full bodies for small ones.
    diff_body = "#{diff_body[0, 16_000]}\n[... diff truncated at 16k chars ...]" if diff_body.length > 16_000

    <<~PROMPT
      Revision "#{kwarg(:revision_summary)}" was just committed. Update the docs in docs/ to reflect it.

      ## What changed (git show HEAD)

      ```
      #{diff_stat}
      ```

      ```
      #{diff_body}
      ```

      ## Your task

      1. `architecture.md` — models, relations, key controllers, routing (touch only what changed)
      2. `conventions.md` — decisions made, gems used, patterns (touch only what changed)
      3. `domain.md` — domain glossary, business rules (touch only what changed)
      4. `frontend.md` — design template + class snippets. Touch ONLY if this revision changed styling decisions (new palette, new component pattern, user-driven design tweak). NEVER touch if styling didn't change. NEVER replace the entire file — small edits to the relevant snippet section.
      5. `revision_notes.md` — APPEND a short section for this revision:
         - What implementation decisions you made and WHY (not a summary)

      ## Rules — IMPORTANT, read carefully

      - Work from the diff above. Do NOT glob, do NOT read the workspace tree, do NOT inspect git history.
      - The only file reads allowed are these five exact paths: `docs/architecture.md`, `docs/conventions.md`, `docs/domain.md`, `docs/frontend.md`, `docs/revision_notes.md`. Do not read the `docs/` directory itself — read the file paths directly.
      - Use Edit (small, targeted edits) or append-only operations. Do not rewrite whole files.
      - If a doc has nothing to update for this revision, skip it — don't write filler.
      - Be terse. Each section in revision_notes is 1-3 sentences max.
    PROMPT
  end

  # W2.7: Commit docs update (allow-empty in case nothing changed)
  cmd(:git_commit_docs) do |my|
    my.command = "sh"
    my.args = [
      "-c",
      "cd #{Shellwords.escape(WORKSPACE)} && git add docs/ 2>/dev/null; " \
      "git diff --cached --quiet && echo '[W2.7] No docs changes, skipping' || " \
      "git commit -m 'docs: update manifest and revision notes'"
    ]
  end

  # W2.8: Report
  ruby(:report) do
    sha = `cd #{Shellwords.escape(WORKSPACE)} && git rev-parse HEAD`.strip
    puts "[W2.8] Completed: #{kwarg(:revision_summary)}"
    puts "[W2.8] Git SHA: #{sha}"
    {
      status: :completed,
      revision_id: kwarg(:revision_id),
      summary: kwarg(:revision_summary),
      git_sha: sha
    }
  end
end
