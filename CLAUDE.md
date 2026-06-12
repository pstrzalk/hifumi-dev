# hifumi.dev

Ruby on Rails application generator — equivalent of Lovable/bolt.new for the Rails ecosystem. Output: clean Rails repo, zero vendor lock-in.

Hosted at **[hifumi.dev](https://hifumi.dev)** · Source: this repo.

## Status (2026-05-15)

- **Phase 1** (Roast 1.1 + Claude CLI spike): **closed**. Pipeline driver → Roast → Claude CLI → verify → remediation validated end-to-end. Code in `spikes/roast/`, results in `spikes/roast/findings.md`.
- **Phase 2** (PoC of the main generator app: RubyLLM + Solid Queue + Roast per Instruction): **closed**. Step 7 added the gated E2E integration test (`E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` — full chain green: `POST /projects` → `ChatRespondJob` → `StartGeneration` → `ExecuteInstructionJob` with the real `bin/roast` subprocess and 3 deterministic revisions) and the `bin/generate` CLI mirror (`full` / `respond` / `execute`). UI demo green on project 38. RubyLLM pinned to `anthropic/claude-haiku-4.5` via OpenRouter.
- **Phase 3** (preview isolation via Kamal + Docker): **closed at the local-PoC level**. Button-driven start/stop, hardened Docker container (`--cap-drop=ALL`, `--read-only`, memory/CPU/pids capped, `preview-internal` network), iframe in side-by-side layout, `CleanupIdlePreviewsJob` reaps previews running >30 min, `instruction.requested` auto-stops a running preview before generation. E2E test gated by `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb`.
- **Phase 4** (production deploy + multi-tenant auth): **closed**. Live at [hifumi.dev](https://hifumi.dev) on Hetzner via Kamal + kamal-proxy. Devise email/password + Sign in with GitHub (OmniAuth). Per-user OpenRouter BYOK (key encrypted at rest via Active Record `encrypts`). Production Dockerfile bundles the `claude` CLI as Roast's transport pointed at OpenRouter.
- **Post-launch review (2026-06-11)**: hardening + robustness findings recorded in `docs/04-reviews/01-post-launch-review.md`. Actioned since: the codegen agent now runs in a per-instruction isolated container (`Roast::Sandbox`); the CVE'd gems were bundle-updated (2026-06-12, CI gates on `bundler-audit`). Phase 5 remains unscoped; the review's last section lists the candidate directions discussed.

Deferred observations from Phase 2 (revisit later, not blockers):
- refused-tool-call pill UX (Step 6) — the `🌀 Starting generation…` flash when the LLM ignores the state rule and Phase 5's tool guard rescues.
- deferred-request handling after `✅ Generation finished.` — see `docs/09-ideas/02-deferred-request-handling.md`.
- Step 7 wall-time margin (Step 7) — real run consumed ~900s vs the spike's 496s; the integration test's `WALL_TIME_BUDGET = 900` sits right at the edge. Bump the budget or investigate W2-phase slowdown (looks heavy on the docs-update agent) before relying on this in CI.

## Documentation structure

All project documentation lives in `docs/`, grouped by topic. Folder and file numbering indicates reading order within each category. Spike code lives separately.

- **`docs/01-vision/`** — product canon: vision, principles, user journey. Read once, reference many times.
- **`docs/02-architecture/`** — technical canon: workflows and decisions, layer integration, tech stack, design system.
- **`docs/03-plans/`** — active implementation plans per phase (currently Phase 2 + Phase 3 analysis).
- **`docs/04-reviews/`** — point-in-time reviews of the running system. `01-post-launch-review.md` (2026-06-11) records the post-Phase-4 robustness/OSS-readiness findings; read it before planning Phase 5.
- **`docs/05-runbooks/`** — step-by-step verification procedures. `01-agent-sandbox-and-model-selection-e2e.md` verifies per-project model selection + agent-sandbox isolation, locally and on prod (`kamal app exec --reuse`).
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

When activating Phase 3 work (or revisiting): add `docs/03-plans/02-phase-3-preview-isolation.md` to the reading order above, before the canon.

Additional sources from the Phase 1 spike:
- `spikes/roast/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `spikes/roast/verify_revision.rb` — verify helper
- `spikes/roast/new_app_driver.rb` — logic moving to `ExecuteInstructionJob` in Phase 2
- `spikes/roast/bin/roast` — wrapper resolving 3 ENV gotchas

## Conventions

- **Rails framing: "Rails Way first"**. Don't position solutions as "event-driven architecture" or "Rails on events" — the community values simplicity and convention over configuration, architectural buzzwords scare people off. Show that Rails tooling already has this, you just need to use it.
- **Design system: Hifumi.** All visible chrome (colors, type, components, status tags, marketing pipeline) follows the Hifumi design system applied 2026-05-01. Tokens + component classes live in a single file: `app/assets/tailwind/application.css`. Use the tokens (`--accent`, `--paper-100`, `--ink-800`, `--hi-font-mono`, etc.) — never hardcode hex values. Status indicators are rectangular outlined boxes in mono caps with a stripe + blinking dot for live states, no emoji. Sentence case in every UI string. See `docs/02-architecture/04-design-system.md` for the full token map, component-to-view inventory, and anti-patterns.
- **Pin `.ruby-version` by writing the file** (Write tool), not via the version manager CLI (`frum local`, `rbenv local`, etc.). User wants to verify state from the file itself.
- **Roast runner**: `bin/roast-claudesubscription` is the dev default (uses Claude Code subscription — wrapper unsets `ANTHROPIC_*` ENV + pins PATH to `.ruby-version` via frum). `bin/roast-openrouter` is the per-token alternative used in production and when `FORCE_OPENROUTER=1` in dev. `bin/roast` (the bundler binstub) calls `bundle exec roast` raw, no env setup — for direct testing only. `ExecuteInstructionJob` picks `-openrouter` in production / when `FORCE_OPENROUTER=1` / whenever sandboxed, else `-claudesubscription`.
- **LLM model selection**: never hardcode a model id at a call site — `lib/llm/stages.rb` (`LLM::Stages`, note the `LLM` acronym inflection) is the registry of the six LLM stages (chat, plan_creation, plan_modification, template, code, docs), their labels, factory defaults, and the curated `AVAILABLE_MODELS` list (full OpenRouter ids only, never `sonnet`/`haiku` aliases). Profiles store per-user defaults (`default_<stage>_model`), projects snapshot their own selection (`<stage>_model`) at creation; selectors live in the build tab (`model_selections/_pane`), the new-project form, and the account integrations pane. A new stage = registry entry + migration on both tables + threading at the call site. Selection applies on the OpenRouter path only — `roast_model_env` keeps claudesubscription runs on the operator's ENV/alias defaults, and an explicit `HIFUMI_DEV_MODEL`/`HIFUMI_DEV_DOCS_MODEL` always wins.
- **Agent sandbox (tenant isolation)**: the codegen agent runs `claude` with `skip_permissions!` on user-controlled prompts — treat it as untrusted code execution, so in production it must NOT run in the shared generator container. `ExecuteInstructionJob#execute_revision` wraps the roast invocation via `Roast::Sandbox.wrap` (`lib/roast/sandbox.rb`, plain builder, returns the `docker run` argv) into a throwaway `--rm` container that mounts ONLY this project's workspace (no `workspace_root`, no `/var/run/docker.sock`), runs entirely as the unprivileged `generator` user (`--user`, `--cap-drop=ALL`, zero cap-adds — uniform uid avoids the capless-root/mixed-ownership deadlock of issue #24; the workspace is re-relaxed `a+rwX` before every sandboxed run), and forwards env (incl. `OPENROUTER_API_KEY` and the per-project `HIFUMI_DEV_*` model selection) **by name** so secrets never hit argv. Gated by `sandboxed?` (production OR `FORCE_AGENT_SANDBOX=1`); dev stays direct (single-tenant, Claude-subscription transport, no Docker). Image = the generator's own, from `HIFUMI_AGENT_IMAGE` (set in `deploy.yml`). Not runtime-verifiable on macOS — see the verification checklist + residuals (generator-side socket, egress, bundle vendoring) in `docs/09-ideas/05-followups.md`.
- **Preview infrastructure**: `lib/preview/preview_manager.rb` (plain Ruby, not a Roast workflow) drives Docker. `lib/preview/Dockerfile{,.base}` are owned by this repo — never read from generated apps. `lib/preview/skeleton/` is the canonical fresh-Rails-app baseline copied into every workspace; regenerate with `bin/preview-regen-skeleton` when bumping Rails. Rebuild the base image with `bin/preview-rebuild-base` after Gemfile changes. The `preview-internal` Docker network is created without `--internal` on Docker Desktop (host port mapping wouldn't work otherwise) — Phase 4 reintroduces strict egress isolation on a Linux production host. In remote mode `PreviewManager#run_container` passes `PREVIEW_HOST=<id>.preview.<domain>` to the container; the skeleton-overlay's `preview_iframe.rb` initializer appends it to `Rails.application.config.hosts` so Rails 8's dev HostAuthorization doesn't 403 the kamal-proxy request.
- **RubyLLM tools must be idempotent within a user turn**. RubyLLM's tool loop will sometimes call the same tool twice in adjacent assistant messages before either result lands, producing the order `assistant(use_X) → assistant(use_Y) → user(result_X) → user(result_Y)` — illegal for Anthropic, and the chat permanently rejects every subsequent message. Tool-side guard pattern: `SuggestPrompts#duplicate_in_turn?` returns an in-band error so the second `tool_use` still gets a `tool_result` and history stays valid. Diagnose corrupt chats with `bin/inspect-chat <project_id>` (works on prod via `kamal app exec`).
