# Rails App Generator

Ruby on Rails application generator — equivalent of Lovable/bolt.new for the Rails ecosystem. Output: clean Rails repo, zero vendor lock-in.

## Status (2026-04-22)

- **Phase 1** (Roast 1.1 + Claude CLI spike): **closed**. Pipeline driver → Roast → Claude CLI → verify → remediation validated end-to-end. Code in `spikes/roast/`, results in `spikes/roast/findings.md`.
- **Phase 2** (PoC of the main generator app: RubyLLM + Solid Queue + Roast per Instruction): Steps 1-6 shipped. Step 6 added live revision UI (Turbo Streams), terminal chat status line, `StartGeneration` concurrency guard, and runtime project state injected into `GeneratorAgent`'s system prompt each turn (`Project#current_state_prompt` + block-based instructions). RubyLLM pinned to `anthropic/claude-haiku-4.5` via OpenRouter. Next: Step 7 (E2E integration test + `bin/generate` CLI mirror) in `docs/03-plans/01-phase-2-poc-generator-app.md`.
- **Phase 3** (preview isolation via Kamal + Docker): **analysis ready** in `docs/03-plans/02-phase-3-preview-isolation.md`. Out of scope for Phase 2.

Deferred observations from Step 6 (revisit later, not blockers): refused-tool-call pill UX (the `🌀 Starting generation…` flash when the LLM ignores the state rule and Phase 5's tool guard rescues); deferred-request handling after `✅ Generation finished.` — see `docs/09-ideas/02-deferred-request-handling.md`.

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

When activating Phase 3: add `docs/03-plans/02-phase-3-preview-isolation.md` to the reading order above, before the canon.

Additional sources from the Phase 1 spike:
- `spikes/roast/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `spikes/roast/verify_revision.rb` — verify helper
- `spikes/roast/new_app_driver.rb` — logic moving to `ExecuteInstructionJob` in Phase 2
- `spikes/roast/bin/roast` — wrapper resolving 3 ENV gotchas

## Conventions

- **Rails framing: "Rails Way first"**. Don't position solutions as "event-driven architecture" or "Rails on events" — the community values simplicity and convention over configuration, architectural buzzwords scare people off. Show that Rails tooling already has this, you just need to use it.
- **Pin `.ruby-version` by writing the file** (Write tool), not via the version manager CLI (`frum local`, `rbenv local`, etc.). User wants to verify state from the file itself.
- **Roast runner**: `bin/roast` by default (Claude Code subscription — wrapper unsets `ANTHROPIC_*` ENV + pins PATH to `.ruby-version`). `bin/roast-openrouter` is the paid per-token fallback when the subscription is insufficient. Do not call `bundle exec roast` directly — it bypasses the wrapper and breaks the pipeline (3 ENV leaks, details in `spikes/roast/findings.md`).
- Repo extracted from the hub `~/projects/pawel-claude/` (2026-04-16) via `git subtree split` — folder history preserved. A backup remains in pawel-claude until the new repo is confirmed OK.
