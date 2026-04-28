---
date: 2026-04-27T12:59:28Z
researcher: Paweł Strzałkowski
git_commit: a0d52019096a280607066e27e9714a94fbcaae33
branch: phase-3-preview-isolation
repository: rails-app-generator
topic: "Phase 3 Preview Isolation — Steps 1-6 complete, resume from Step 7"
tags: [implementation, strategy, phase-3, preview, docker, solid-queue]
status: complete
last_updated: 2026-04-27
last_updated_by: Paweł Strzałkowski
type: implementation_strategy
---

# Handoff: Phase 3 Preview Isolation — resume from Step 7

## Task(s)

Implementing the 9-step Phase 3 plan: button-driven, hardened Docker preview pane next to the chat. Working on a feature branch `phase-3-preview-isolation` off `main`. Each step lands as one commit and is verified before moving on.

**Status by step**:
- ✅ Step 1 — Pre-baked Rails skeleton refactor (`532b546`)
- ✅ Step 2 — Project preview state columns + enum (`bcf5765`)
- ✅ Step 3 — Dockerfile + base image build infra (`c7b8223`)
- ✅ Step 4 — PreviewManager (`9e0fa26`)
- ✅ Step 5 — Jobs + :preview queue (`da4307f`)
- ✅ Step 6 — Wiring + UI + auto-stop subscriber (`a0d5201`)
- ⏳ **Step 7 — CleanupIdlePreviewsJob (next up)**
- ⏳ Step 8 — Gated E2E integration test (`E2E_PREVIEW=1`)
- ⏳ Step 9 — Canon / CLAUDE.md / README / memory updates

All commits land on `phase-3-preview-isolation`; main is untouched. Suite green at every step (last: 144 runs, 0 failures, 1 preexisting skip).

## Critical References

- **Implementation plan** (always re-read first): `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md`. Already has Step-1-through-6 checkmarks filled in with manual-verification results, plus Step-3 fallback note (`--internal` blocks `-p` on Docker Desktop), Step-4 `storage/`-mount + `/app/log` tmpfs corrections, and Step-6a X-Frame-Options overlay finding.
- **Kickoff research**: `thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md`.
- **Phase 3 analysis (precursor)**: `docs/03-plans/02-phase-3-preview-isolation.md`.
- **Project canon**: `CLAUDE.md` reading order and conventions still apply.

## Recent changes

The whole branch tip is mine. Last six commits (latest first):

- `a0d5201` — phase 3 step 6: PreviewsController + previews UI + auto-stop on instruction.requested
- `da4307f` — phase 3 step 5: StartPreviewJob, StopPreviewJob, :preview queue
- `9e0fa26` — phase 3 step 4: lib/preview/preview_manager.rb (start/stop/cleanup)
- `c7b8223` — phase 3 step 3: lib/preview/Dockerfile{,.base} + bin/preview-rebuild-base
- `bcf5765` — phase 3 step 2: Project preview state columns + enum
- `532b546` — phase 3 step 1: lib/preview/skeleton + cp_r-based prepare_workspace (replace rails new)

Notable file additions to remember when designing Step 7:
- `app/jobs/start_preview_job.rb`, `app/jobs/stop_preview_job.rb` — both `queue_as :preview`, both delegate to `Preview::PreviewManager`. Step 7's `CleanupIdlePreviewsJob` should mirror this shape.
- `config/queue.yml:8-12` — `:preview` worker (1 thread, 1 process, polling 1 s).
- `config/recurring.yml` — currently has only the production `clear_solid_queue_finished_jobs` block; Step 7 needs to add `default:`/`development:` blocks for the cleanup recurring schedule.
- `lib/preview/preview_manager.rb` — `MEMORY_LIMIT`, `CPU_LIMIT`, etc. are class constants; idle-cleanup logic should not duplicate them.
- `app/models/project.rb:8-15` — `preview_state` enum + prefix `:preview` (so `preview_running?` etc. are auto-generated).

## Learnings

These are the things that aren't already obvious from the plan or the code, but tripped me up during 1-6 and would trip up the next agent:

1. **Existing dev server may already hold port 3000.** `bin/dev` will fail with EADDRINUSE if you don't kill the user's existing server first. For my own Step-5 manual verification I ran just `bin/jobs` (worker only) instead — that bypasses the port collision and is enough to test job-queue behavior.
2. **Minitest 6 (Rails 8.1.3) dropped `Object#stub` and shipped no `minitest/mock`.** No Mocha is in the Gemfile. Workarounds used in this branch:
   - `test/lib/preview/preview_manager_test.rb` — injectable runner + injectable `health_timeout`/`health_interval` constructor args (`lib/preview/preview_manager.rb:22-32`).
   - `test/jobs/start_preview_job_test.rb`, `stop_preview_job_test.rb` — singleton-class `alias_method` swap to redirect `Preview::PreviewManager.new` to a fake.
   Use one of these patterns for new tests; do NOT add Mocha.
3. **Zeitwerk eager-load was broken on `main`** (independent of Phase 3) because `lib/roast/*.rb` are Roast DSL files invoked via subprocess and `abort()` at top-level when env vars are missing. Step 4 fixed this by extending `autoload_lib(ignore: …)` to skip `roast`, `preview/skeleton`, and `preview/skeleton-overlay` (`config/application.rb:17-29`). `bundle exec rails zeitwerk:check` is now green; keep it that way.
4. **Plan said `-v db:/app/db`. Rails 8 puts SQLite under `storage/`.** Fixed in `lib/preview/preview_manager.rb#run_container` — mount is now `storage:/app/storage`. Also added `--tmpfs /app/log:size=16m` because `--read-only` blocks Rails from opening `log/development.log` even with `RAILS_LOG_TO_STDOUT=1` (Rails touches the file at boot before honoring the env var). Both corrections recorded inline in `run_container`.
5. **`--internal` networks silently drop `-p` host port mapping on Docker Desktop / macOS.** Plan's fallback path was taken: `Preview::PreviewManager.ensure_network!` creates the network *without* `--internal`. Cost is recorded in the plan's "What We're NOT Doing" section. Phase 4 reintroduces strict egress isolation on a Linux production host where `--internal` actually works.
6. **X-Frame-Options blocks cross-port iframing.** Generator runs at `localhost:3000`, preview at `localhost:3038` — different origins. Rails default `X-Frame-Options: SAMEORIGIN` blocks the embed. Fixed via `lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb` (deletes the header). Overlay ships into every fresh workspace at init time. Existing project_38 needed the file copied in manually before its rebuild.
7. **`Preview::PreviewManager#broadcast` calls `turbo-rails` partial render.** Tests need either the real partial in place (already true after Step 6) or the singleton-swap pattern. Don't reintroduce the placeholder pane.
8. **Auto-stop subscriber LGTM but Phase-2 LLM behavior intervenes.** During Step-6 manual verification, the LLM said "I've queued up the fix" without actually invoking the `start_generation` tool, so `instruction.requested` never fired and the preview never auto-stopped. The auto-stop wiring itself is correct — verified by replaying `instruction.requested` from `rails runner`. This is the open Phase-2 deferred-request issue (CLAUDE.md "deferred observations"). Don't chase it during Phase 3.
9. **Workspaces created before Phase 3** (e.g. `~/projects/rails-app-generator-workspaces/project_38/`) lack `bin/preview-entrypoint` AND `config/initializers/preview_iframe.rb` because they were seeded by the old `rails new` flow. For ad-hoc testing, copy both from `lib/preview/skeleton-overlay/` once. Fresh workspaces (post-Step-1) inherit them automatically via `init_rails_app`.
10. **`init_rails_app` writes a per-workspace `master.key` via `ActiveSupport::EncryptedFile.generate_key`** — skeleton ships without crypto so we don't bake a shared secret into git. `.gitignore` defends `lib/preview/skeleton/config/master.key` and `credentials.yml.enc`.

## Artifacts

Read in this order to resume cleanly:

1. `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` — the plan, with Step-1-through-6 checkmarks + correction notes already filled in.
2. `CLAUDE.md` (project root) — Phase 3 status, conventions, deferred observations.
3. This handoff (you're reading it).
4. `lib/preview/preview_manager.rb` — the core class. The Step-4 storage-mount + log-tmpfs corrections are documented inline.
5. `config/initializers/event_subscribers.rb:21-28` — the new `instruction.requested` → `StopPreviewJob` subscriber, for Step 7's mental model.
6. `app/jobs/start_preview_job.rb` and `stop_preview_job.rb` — shape to mirror in Step 7's `CleanupIdlePreviewsJob`.

## Action Items & Next Steps

Pick up at **Step 7 — CleanupIdlePreviewsJob**, plan section starting at the Step-7 heading in `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md`. Specifically:

1. Add `app/jobs/cleanup_idle_previews_job.rb` (`queue_as :preview`, `IDLE_TIMEOUT = 30.minutes`). Iterate `Project.where(preview_state: :running).where("preview_started_at < ?", IDLE_TIMEOUT.ago)` and `StopPreviewJob.perform_later` for each.
2. Update `config/recurring.yml` per the plan: add a `default:` block (which dev inherits) running `cleanup_idle_previews` every 5 minutes; keep production's `clear_solid_queue_finished_jobs` as-is.
3. Add `test/jobs/cleanup_idle_previews_job_test.rb` covering three branches: idle running → enqueue, fresh running → no enqueue, stopped → no enqueue.
4. Verify `bundle exec rails test` is still green.
5. Manual check: leave `preview-38` running, set `preview_started_at = 31.minutes.ago` from `rails c`, wait or `CleanupIdlePreviewsJob.perform_now`, confirm `StopPreviewJob` fired (via worker logs and `docker ps`).
6. Commit using the plan's prescribed message: `phase 3 step 7: CleanupIdlePreviewsJob recurring every 5 min`.

After Step 7: Step 8 is the gated E2E test (`E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb`). Step 9 is canon updates (W3 doc, vision Step 5, tech stack, CLAUDE.md status, README "Running previews locally", memory note about no-headless-browser-tests).

Optional: the only manual check skipped on Step 6 is the docker-rmi-base + retry path. Failure branches are unit-tested in Step 4; one 30-second click-through would close the visual loop — easy to do during Step-7 manual verification.

## Other Notes

- **Live state when handoff was written**: `preview-38` container stopped (DB state=stopped, container_id nil, all preview_* columns clean). `preview-base:latest` image still cached. User's `bin/dev` (PIDs starting at 19745) still running on port 3000 with all three queue workers up. Docker Desktop running.
- **Test count**: 144 runs / 464 assertions / 0 failures / 1 (preexisting frum-env) skip on commit `a0d5201`.
- **Previous workspace seeded for live testing**: `~/projects/rails-app-generator-workspaces/project_38/`. Already has `bin/preview-entrypoint` and `config/initializers/preview_iframe.rb` patched in (manual `cp` during Step 6 verification). Useful for Step 7 manual testing without needing a fresh generation.
- **Branch safety**: branch is solely `phase-3-preview-isolation`; main is `main` and untouched. No PR opened yet — that happens after Step 9.
- **Recurring.yml dev gotcha**: per the plan, the cleanup recurring entry must land in `default:` (which `development:` inherits) so it actually runs in dev, not production-only. Current `recurring.yml` has only `production:` block with the unrelated solid-queue cleanup — Step 7 needs to refactor it to the default+production pattern shown in the plan.
- **Memory updates** (`/Users/pawel/.claude/projects/-Users-pawel-projects-rails-app-generator/memory/`): no changes made during Phase 3 yet. Step 9 should touch `project_verify_no_system_tests.md` to note that Phase 3 verified preview via host-side `curl /up` + gated E2E test, not Selenium. Also worth adding a new memory about the `--internal` Docker Desktop fallback so future sessions don't relitigate.
