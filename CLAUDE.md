# Rails App Generator

Ruby on Rails application generator — equivalent of Lovable/bolt.new for the Rails ecosystem. Output: clean Rails repo, zero vendor lock-in.

## Status (2026-04-27)

- **Phase 1** (Roast 1.1 + Claude CLI spike): **closed**. Pipeline driver → Roast → Claude CLI → verify → remediation validated end-to-end. Code in `spikes/roast/`, results in `spikes/roast/findings.md`.
- **Phase 2** (PoC of the main generator app: RubyLLM + Solid Queue + Roast per Instruction): **closed**. Step 7 added the gated E2E integration test (`E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` — full chain green: `POST /projects` → `ChatRespondJob` → `StartGeneration` → `ExecuteInstructionJob` with the real `bin/roast` subprocess and 3 deterministic revisions) and the `bin/generate` CLI mirror (`full` / `respond` / `execute`). UI demo green on project 38. RubyLLM pinned to `anthropic/claude-haiku-4.5` via OpenRouter.
- **Phase 3** (preview isolation via Kamal + Docker): **closed at the local-PoC level**. Button-driven start/stop, hardened Docker container (`--cap-drop=ALL`, `--read-only`, memory/CPU/pids capped, `preview-internal` network), iframe in side-by-side layout, `CleanupIdlePreviewsJob` reaps previews running >30 min, `instruction.requested` auto-stops a running preview before generation. E2E test gated by `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb`. Plan: `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md`. **Phase 4** (production deploy on Hetzner/DO with kamal-proxy + DNS + wildcard cert + strict `--internal` network) is the next candidate.

Deferred observations from Phase 2 (revisit later, not blockers):
- refused-tool-call pill UX (Step 6) — the `🌀 Starting generation…` flash when the LLM ignores the state rule and Phase 5's tool guard rescues.
- deferred-request handling after `✅ Generation finished.` — see `docs/09-ideas/02-deferred-request-handling.md`.
- Step 7 wall-time margin (Step 7) — real run consumed ~900s vs the spike's 496s; the integration test's `WALL_TIME_BUDGET = 900` sits right at the edge. Bump the budget or investigate W2-phase slowdown (looks heavy on the docs-update agent) before relying on this in CI.

## Documentation structure

All project documentation lives in `docs/`, grouped by topic. Folder and file numbering indicates reading order within each category. Spike code lives separately.

- **`docs/01-vision/`** — product canon: vision, principles, user journey. Read once, reference many times.
- **`docs/02-architecture/`** — technical canon: workflows and decisions, layer integration, tech stack.
- **`docs/03-plans/`** — active implementation plans per phase (currently Phase 2 + Phase 3 analysis).
- **`docs/09-ideas/`** — brainstorm / idea dump (explicitly marked as non-canon).
- **`spikes/roast/`** — reference implementation of Phase 1 (proven, don't touch without reason). Future spikes: `spikes/<name>/`.

## Reading order when resuming

1. `docs/03-plans/01-phase-2-poc-generator-app.md` — Phase 2 plan: architectural decisions, DoD, steps 1-7, alternatives table, open questions
2. `spikes/roast/findings.md` — what was validated in Phase 1, what gotchas surfaced
3. `docs/01-vision/02-user-journey.md` — user story, data model, architecture (canon)
4. `docs/02-architecture/01-workflows-and-decisions.md` — W1-W6 workflow definitions + D1-D6 decisions + Roast example
5. `docs/02-architecture/02-layer-integration.md` — RubyLLM ↔ Roast ↔ Solid Queue via event bus
6. `docs/02-architecture/03-tech-stack.md` — gems (generator stack vs. generated apps stack)
7. `docs/01-vision/01-vision-and-principles.md` — vision, fixed assumptions, A/B Quick/Guided paths, deferred

When activating Phase 3 work (or revisiting): add `docs/03-plans/02-phase-3-preview-isolation.md` (analysis precursor) and `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` (the implementation plan, with manual-verification notes filled in) to the reading order above, before the canon.

Additional sources from the Phase 1 spike:
- `spikes/roast/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `spikes/roast/verify_revision.rb` — verify helper
- `spikes/roast/new_app_driver.rb` — logic moving to `ExecuteInstructionJob` in Phase 2
- `spikes/roast/bin/roast` — wrapper resolving 3 ENV gotchas

## Conventions

- **Rails framing: "Rails Way first"**. Don't position solutions as "event-driven architecture" or "Rails on events" — the community values simplicity and convention over configuration, architectural buzzwords scare people off. Show that Rails tooling already has this, you just need to use it.
- **Pin `.ruby-version` by writing the file** (Write tool), not via the version manager CLI (`frum local`, `rbenv local`, etc.). User wants to verify state from the file itself.
- **Roast runner**: `bin/roast` by default (Claude Code subscription — wrapper unsets `ANTHROPIC_*` ENV + pins PATH to `.ruby-version`). `bin/roast-openrouter` is the paid per-token fallback when the subscription is insufficient. Do not call `bundle exec roast` directly — it bypasses the wrapper and breaks the pipeline (3 ENV leaks, details in `spikes/roast/findings.md`).
- **Preview infrastructure**: `lib/preview/preview_manager.rb` (plain Ruby, not a Roast workflow) drives Docker. `lib/preview/Dockerfile{,.base}` are owned by this repo — never read from generated apps. `lib/preview/skeleton/` is the canonical fresh-Rails-app baseline copied into every workspace; regenerate with `bin/preview-regen-skeleton` when bumping Rails. Rebuild the base image with `bin/preview-rebuild-base` after Gemfile changes. The `preview-internal` Docker network is created without `--internal` on Docker Desktop (host port mapping wouldn't work otherwise) — Phase 4 reintroduces strict egress isolation on a Linux production host.
- Repo extracted from the hub `~/projects/pawel-claude/` (2026-04-16) via `git subtree split` — folder history preserved. A backup remains in pawel-claude until the new repo is confirmed OK.
