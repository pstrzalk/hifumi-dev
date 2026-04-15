# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# W2: Wykonanie pojedynczej rewizji — Implement → Verify → Commit
# Zgodne z agents-vs-workflows.md (W2.1–W2.8 + W2.R remediation + W2.F failure path).
#
# Uruchomienie:
#   REVISION_WORKSPACE=/path/to/app bundle exec roast revision_workflow.rb -- \
#     revision_id=1 \
#     revision_summary="Add Todo model" \
#     revision_prompt="Create Todo model with title, body, done. Migration + tests."
#
# Model override przez ENV:
#   CLAUDE_MODEL=haiku REVISION_WORKSPACE=... bundle exec roast revision_workflow.rb -- ...

require "shellwords"
require_relative "verify_revision"

WORKSPACE = ENV.fetch("REVISION_WORKSPACE") do
  abort("REVISION_WORKSPACE env var is required (path to Rails workspace).")
end
CLAUDE_MODEL = ENV.fetch("CLAUDE_MODEL", "sonnet")

# Shared state między krokami workflow (Roast DSL-blocks nie dzielą `metadata`
# ani instance variables). Używany do przeniesienia verify errors z W2.4 verify
# do W2.R repeat(:remediate) block.
WORKFLOW_STATE = {}

config do
  agent do
    provider :claude
    model CLAUDE_MODEL
    working_directory WORKSPACE
    skip_permissions!
    show_stats!
  end
  cmd { display! }
end

# --- W2.R: Remediation scope (max 2 próby) ---

execute(:fix_and_reverify) do
  agent(:fix) do |_, errors, idx|
    <<~PROMPT
      Weryfikacja nie przeszła (próba #{idx + 1}/2).

      Błędy:

      #{errors}

      Napraw dokładnie to, co jest zepsute. Nie zmieniaj podejścia.
    PROMPT
  end

  ruby(:reverify) do
    result = VerifyRevision.run(WORKSPACE)
    fail!(VerifyRevision.format_errors(result)) if VerifyRevision.failed?(result)
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
  # W2.1: Mark generating (w produkcji: update DB)
  ruby(:log_start) do
    puts "[W2.1] Revision ##{kwarg(:revision_id)}: #{kwarg(:revision_summary)}"
    puts "[W2.1] Workspace: #{WORKSPACE}"
    puts "[W2.1] Model: #{CLAUDE_MODEL}"
  end

  # W2.2: Build prompt z app manifest + revision notes
  ruby(:build_prompt) do
    docs_dir = File.join(WORKSPACE, "docs")
    manifest = Dir.glob("#{docs_dir}/{architecture,conventions,domain}.md")
                  .map { |f| "### #{File.basename(f)}\n\n#{File.read(f)}" }
                  .join("\n\n")
    notes_path = File.join(docs_dir, "revision_notes.md")
    revision_notes = File.exist?(notes_path) ? File.read(notes_path) : ""

    parts = []
    parts << "## Zadanie\n\n#{kwarg(:revision_prompt)}"
    parts << "## Podsumowanie (git commit message)\n\n#{kwarg(:revision_summary)}"

    unless manifest.empty?
      parts << "## Aktualny stan aplikacji (manifest)\n\n#{manifest}"
    end

    unless revision_notes.empty?
      parts << "## Kontekst z poprzednich rewizji\n\n#{revision_notes}"
    end

    parts << <<~RULES
      ## Zasady
      - Rails Way: konwencje, generatory, wbudowane rozwiązania
      - Tailwind CSS do stylowania
      - Hotwire (Turbo + Stimulus), zero React/Vue
      - Minitest, nie RSpec
      - Pisz testy dla nowej funkcjonalności
      - Nie twórz pustych katalogów ani plikow, które nie są potrzebne
      - Pracujesz w #{WORKSPACE} — wszystkie ścieżki względne do tego katalogu
    RULES

    parts.join("\n\n")
  end

  # W2.3: Implement — Claude CLI generuje kod
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

  # W2.R: Remediation loop — skip jeśli verify od razu przeszedł
  repeat(:remediate, run: :fix_and_reverify) do
    skip! if ruby?(:verify)
    puts "[W2.R] Verify failed, entering remediation loop"
    WORKFLOW_STATE[:verify_errors] || "initial verification failed"
  end

  # W2.F: Failure guard — jeśli verify i remediation failują, nie commitujemy
  ruby(:ensure_passing) do
    passed = ruby?(:verify) || (ruby?(:remediate) && repeat!(:remediate).value == :succeeded)
    unless passed
      puts "[W2.F1] Verification failed after remediation — aborting without commit"
      puts "[W2.F2] Resetting uncommitted changes in workspace"
      system("cd #{Shellwords.escape(WORKSPACE)} && git reset --hard HEAD && git clean -fd")
      fail!("W2.F: revision failed, workspace reset to parent HEAD")
    end
    "ready to commit"
  end

  # W2.5: Git commit kod
  cmd(:git_commit) do |my|
    summary = kwarg(:revision_summary)
    my.command = "sh"
    my.args = ["-c", "cd #{Shellwords.escape(WORKSPACE)} && git add -A && git commit -m #{Shellwords.escape(summary)}"]
  end

  # W2.6: Update app manifest + revision notes
  agent(:update_docs) do
    <<~PROMPT
      Rewizja "#{kwarg(:revision_summary)}" została zacommitowana.
      Zaktualizuj dokumentację w docs/:

      1. `architecture.md` — modele, relacje, kluczowe kontrolery, routing
      2. `conventions.md` — podjęte decyzje, użyte gemy, wzorce
      3. `domain.md` — słownik domeny, reguły biznesowe
      4. `revision_notes.md` — DOPISZ (append) sekcję dla tej rewizji:
         - Jakie decyzje implementacyjne podjąłeś i DLACZEGO
         - Nie summary ("dodano model") tylko kontekst ("użyto STI bo...")
         - Te notatki będą karmione do następnej rewizji jako kontekst

      Jeśli plik nie istnieje — utwórz. Jeśli istnieje — aktualizuj tylko co trzeba.
      Nie nadpisuj całych plików od zera.
    PROMPT
  end

  # W2.7: Commit docs update (allow-empty na wypadek gdyby nic się nie zmieniło)
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
