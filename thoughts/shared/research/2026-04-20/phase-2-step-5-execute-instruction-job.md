---
date: 2026-04-20T00:23:00+02:00
researcher: Paweł Strzałkowski
git_commit: d485c8c4b440df0ca18745998d0f30aeff90cb02
branch: main
repository: rails-app-generator
topic: "Phase 2 Step 5 — ExecuteInstructionJob + Roast integration: codebase state, constraints, open questions"
tags: [research, codebase, phase-2, step-5, execute-instruction-job, roast, solid-queue, event-bus]
status: complete
last_updated: 2026-04-20
last_updated_by: Paweł Strzałkowski
---

# Research: Phase 2 Step 5 — `ExecuteInstructionJob` + Roast integration

**Date**: 2026-04-20T00:23:00+02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: d485c8c4b440df0ca18745998d0f30aeff90cb02
**Branch**: main
**Repository**: rails-app-generator

## Research Question

Step 5 of Phase 2 moves the spike's `new_app_driver.rb` logic into a Solid Queue job — `ExecuteInstructionJob` — that (a) prepares the workspace once per project, (b) iterates each Revision and shells out to `bin/roast lib/roast/revision_workflow.rb` with per-revision kwargs, (c) persists status + metrics + `git_sha`, and (d) emits `revision.*` and `instruction.*` events. What does the codebase look like today, what constraints must Step 5 satisfy, and what decisions still need to be made before implementation?

## Summary

Step 4 closed on `d485c8c` (2026-04-19): `StartGeneration` persists `Instruction` + chained `Revision` rows, fires `instruction.requested`, and returns a confirmation to the chat. **No subscriber exists** — the notification fires into the void, deliberately, so Step 5 shapes the subscriber and job from scratch (`thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md:7`).

The infrastructure is in place to drop Step 5's job on top:

- **Roast pipeline already bootable** — `bin/roast`, `bin/roast-openrouter`, `lib/roast/revision_workflow.rb`, `lib/roast/verify_revision.rb`, `lib/roast/smoke_workflow.rb`, all copied from the spike and validated by `tmp/smoke_workflow.sh` (Step 1, commit `61667ee`).
- **DB schema complete** — `Revision` has `prompt`, `started_at`, `finished_at`, `metrics (json)`, `git_sha`, `status` enum with the four states the job transitions through (Step 4 Phase 1 migration `20260418172451`).
- **Event bus conventions established** — `instruction.requested` is the only instrumentation site today (`app/tools/start_generation.rb:48-51`); its payload shape (`instruction_id:`) is mirrored in the planned `revision.*` / `instruction.*` events documented in `docs/02-architecture/02-layer-integration.md:37-52`.
- **Solid Queue installed but single-pool** — `config/queue.yml:1-19` defines one worker with `queues: "*"`, `threads: 3`, `processes: 1`. No `generation` queue, no `limits_concurrency` DSL in use.
- **`Project#workspace_path` already derives `"storage/workspaces/#{id}"`** (`app/models/project.rb:8-10`); `.gitignore` excludes `/storage/*` (`.gitignore:25`) which covers `storage/workspaces/` transitively.
- **Test patterns exist** — notification-subscription assertions in `test/tools/start_generation_test.rb:62-77`, Turbo broadcast assertions in `test/models/message_test.rb`, a job test scaffold in `test/jobs/chat_respond_job_test.rb`.

The Step 5 implementation maps roughly 1:1 to the spike's `new_app_driver.rb` with six substitutions: (a) plan comes from DB instead of `plans.rb`, (b) workspace is `Rails.root.join(project.workspace_path)` instead of a CLI flag, (c) metrics land in `revision.metrics` jsonb instead of a file, (d) SHA lands in `revision.git_sha`, (e) status transitions via AR enum, (f) events replace `puts` logs.

## Detailed Findings

### 1. What Step 5 must produce — DoD from the plan

`docs/03-plans/01-phase-2-poc-generator-app.md:310-389` is the canonical Step 5 pseudocode. Key extracts:

**Job structure** (lines 314-339):
```ruby
class ExecuteInstructionJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = Rails.root.join("storage/workspaces/#{project.id}").to_s

    prepare_workspace(project, workspace) unless project.workspace_initialized?
    rails_new(project, workspace) unless File.exist?(File.join(workspace, "Gemfile"))
    init_docs_baseline(workspace) unless File.exist?(File.join(workspace, "docs"))

    instruction.revisions.order(:position).each do |revision|
      execute_revision(revision, workspace)
      break if revision.failed?
    end

    instruction.update!(phase: instruction.revisions.all?(&:completed?) ? :completed : :failed)
    ActiveSupport::Notifications.instrument(
      instruction.completed? ? "instruction.completed" : "instruction.failed",
      instruction_id: instruction.id
    )
  end
  # ...
end
```

**`execute_revision` core shape** (lines 342-377):
- Transition `status: :generating`, set `started_at`, fire `revision.started`.
- Build env hash: `{"REVISION_WORKSPACE" => workspace, "CLAUDE_MODEL" => ENV.fetch("CLAUDE_MODEL", "sonnet")}`.
- Build args: `[bin/roast, lib/roast/revision_workflow.rb, --, revision_id=…, revision_summary=…, revision_prompt=…]`.
- `ok = system(env, *args)` — synchronous blocking.
- Capture `$?.exitstatus`, wall time, `git_head(workspace)` → `metrics = { wall_seconds:, exit_code:, git_sha: }`.
- On success: update `status: :completed, finished_at:, git_sha:, metrics:`, fire `revision.completed` with `git_sha:`.
- On failure: update `status: :failed, finished_at:, metrics:`, fire `revision.failed` with `error: "exit #{exit_code}"`.

**Additional requirements** (lines 383-389):
- `ApplicationJob`: `queue_as :generation` + `retry_on StandardError, wait: :polynomially_longer, attempts: 1` (no auto-retry).
- Solid Queue: `generation` queue with concurrency 1.
- `.gitignore`: add `storage/workspaces/` (already implicitly covered by `/storage/*`).
- No hard timeout (spike max = 226s/revision; add 20-min cap in Step 7 if needed).

**DoD** (line 389): manually created `Instruction + 1 Revision` → `ExecuteInstructionJob.perform_now(id)` → Rails app exists in workspace, git has 2 commits (scaffolding + revision), `Revision` is `completed` with `git_sha` set.

### 2. Current codebase — what already exists

#### `bin/roast` wrapper (`bin/roast:1-27`)

Three ENV leaks mitigated in Phase 1 are neutralised here; do NOT call `bundle exec roast` directly (CLAUDE.md convention, commit `b94e9a7` in spike):

1. Unsets `ANTHROPIC_API_KEY / AUTH_TOKEN / BASE_URL / DEFAULT_*_MODEL` so Claude CLI uses subscription OAuth.
2. `cd "$(dirname "$0")/.."` to repo root.
3. Pins `PATH` to `$HOME/.frum/versions/$(cat .ruby-version)/bin` so the frum shim resolves `bundle` under the right Ruby (`.ruby-version` = `4.0.2`).
4. `exec bundle exec roast "$@"`.

The paid fallback `bin/roast-openrouter:1-18` sets `ANTHROPIC_BASE_URL=https://openrouter.ai/api` + `ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY` and pins `anthropic/claude-*-4.x` models explicitly.

#### `lib/roast/revision_workflow.rb` (1-206)

Copied from spike. Key surfaces for the job:

- **ENV contract**: `REVISION_WORKSPACE` (required) and `CLAUDE_MODEL` (defaults `"sonnet"`), lines 21-24.
- **kwarg contract**: `revision_id`, `revision_summary`, `revision_prompt` — passed after `--` (spike findings §3, `kwarg(:...)` not `--flag val`).
- **Exit code convention**: Roast exits non-zero when any `fail!` reaches a top-level `execute` block without rescue. `W2.F` guard (lines 146-155) calls `fail!("W2.F: revision failed, workspace reset to parent HEAD")` and runs `git reset --hard HEAD && git clean -fd` before failing — so the workspace is clean even on failure.
- **Side effect on success**: `W2.5` commits code, `W2.7` commits docs (allow-empty), `W2.8` prints `git_sha` via `git rev-parse HEAD`. The job re-reads `git_sha` itself via `git_head(workspace)` helper (not through subprocess stdout — output is for operator observability, not parseable).

#### `lib/roast/verify_revision.rb` (1-66)

- **Check order**: `bundle_check → db:prepare → herb_lint (skipped if gem absent) → boot_check → rails_test (skipped if no tests)`.
- **`with_clean_bundler_env`**: unsets `BUNDLE*/BUNDLER*/RUBYOPT` before shelling to workspace (`lib/roast/verify_revision.rb:58-65`). Mitigates the third ENV leak (spike findings §3). The workspace's `bin/rails` needs this to find its own Gemfile.

#### `lib/roast/smoke_workflow.rb` + `tmp/smoke_workflow.sh`

Asserts the pipeline boots: unset ENV (`ANTHROPIC_*` + `BUNDLE_GEMFILE`), correct Ruby, `VerifyRevision` loads, DSL parses. Runs in seconds with no token spend. **Step 5's CI can reuse this to assert the wrapper still works before each revision** (optional, currently only manual).

#### Data model (`db/schema.rb`)

- **`projects`** (lines 106-110): `id`, `name (not null)`, timestamps. **No `workspace_path` column** — it was removed in migration `20260418151522`, now a method on the model (`app/models/project.rb:8-10`).
- **`instructions`** (lines 51-62): `project_id (not null, cascade)`, `anchor_message_id (not null, cascade)`, `description (not null)`, `phase (default 'researching')`, `user_intent (text)`, `research_output (text)`, timestamps.
- **`revisions`** (lines 112-130): `project_id (cascade)`, `instruction_id (cascade)`, `parent_id (nullify)`, `position (not null)`, `status (default 'pending')`, `summary (not null)`, `prompt (not null, default '')`, `git_sha`, `started_at`, `finished_at`, `metrics (json, default {}, not null)`. Unique composite index on `[instruction_id, position]` (line 126).

Enums (from `app/models/instruction.rb:6-13`, `app/models/revision.rb:6-11`):
- `Instruction.phase`: `researching / planning / implementing / completed / failed / cancelled` (Step 5 transitions `implementing → completed` or `implementing → failed`).
- `Revision.status`: `pending / generating / completed / failed` (Step 5 transitions `pending → generating → (completed|failed)`).

#### Jobs

- **`ApplicationJob`** (`app/jobs/application_job.rb:1-7`) is vanilla — just the default template comments. **Step 5 introduces the first non-trivial configuration** (`queue_as :generation`, retry policy).
- **`ChatRespondJob`** (`app/jobs/chat_respond_job.rb:1-42`) uses `queue_as :default` and calls `GeneratorAgent.find(chat_id).complete { |chunk| … }` (via `agent.complete`, not `chat.complete` — GeneratorAgent wraps Chat with tools preloaded).

#### Solid Queue config

`config/queue.yml:1-19`:
```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: "*"
      threads: 3
      processes: <%= ENV.fetch("JOB_CONCURRENCY", 1) %>
      polling_interval: 0.1
```

One worker pool, handles all queues, 3 threads. **`generation` queue is not declared — Step 5 must either add it or rely on `limits_concurrency`** (see Open Questions).

#### Turbo Streams wiring

- `app/models/message.rb:5-29` auto-broadcasts on create (`broadcast_append_later_to chat.project, target: "messages"`) and update (`broadcast_replace_later_to chat.project, target: dom_id(self)`).
- `app/models/tool_call.rb:8-14` touches its message after commit, re-triggering the update broadcast (RubyLLM attaches tool_calls AFTER message save — memory `project_ruby_llm_message_lifecycle`).
- `app/tools/suggest_prompts.rb:24-31` broadcasts suggestion cards to `target: "suggestions"` (manual, because the view element isn't backed by an AR row).
- `app/jobs/chat_respond_job.rb:34-41` broadcasts each streaming chunk via `Turbo::StreamsChannel.broadcast_replace_to(project, target: dom_id(message), …)`.

**No `revision` or `instruction` broadcasting exists yet.** Step 5 (and the follow-up Step 6) will introduce them via event subscribers, not model callbacks (per `docs/02-architecture/02-layer-integration.md:163-179`).

#### Event bus

- **Publication**: only `app/tools/start_generation.rb:48-51` (`instruction.requested`).
- **Subscription**: none. No `config/initializers/event_subscribers.rb`.
- **Test pattern**: `test/tools/start_generation_test.rb:62-77` subscribes inside a test, captures payloads, `unsubscribe` in `ensure`. Identical pattern will work for asserting `revision.started` etc. from `ExecuteInstructionJob` unit tests.

#### RubyLLM configuration

`config/initializers/ruby_llm.rb:1-7` pins `default_model = "anthropic/claude-haiku-4.5"` via OpenRouter. `use_new_acts_as = true`. **This is Haiku for the chat layer + CreatePlan — totally unrelated to the Claude CLI that Roast invokes inside `agent(:generate_code)`**. Roast's agent uses `CLAUDE_MODEL` ENV (default `sonnet`, subscription OAuth via `bin/roast`).

### 3. Spike's `new_app_driver.rb` — what maps 1:1

`spikes/roast/new_app_driver.rb:36-58` is the orchestration that moves into `ExecuteInstructionJob#perform`:

| Driver method | Mapped to | Notes |
|---|---|---|
| `prepare_workspace` (62-68) | Same helper in job | In the spike, **wipes** an existing workspace with `FileUtils.rm_rf`. Step 5 must NOT wipe (workspace already exists on retry), must create parent dirs idempotently |
| `rails_new` (70-80) | Same helper | Flags `--css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci`; `cd workspace_root && rails new app_name …` |
| `init_git_and_docs` (82-94) | `init_docs_baseline` per plan | Creates `docs/architecture.md`, `conventions.md`, `domain.md`, `revision_notes.md`; `git add -A && git commit -m 'docs: scaffolding baseline'` |
| `execute_revision` (96-122) | Same helper | Spike captures `metrics[:revisions]` array in memory + writes JSON file; job persists per-revision to DB |
| `dispatch_roast` (124-144) | Inlined into `execute_revision` | Spike uses `system(env, *args, chdir: SPIKE_DIR)`; job uses `system(env, *args)` with no chdir (bin/roast does its own `cd` to repo root) |
| `git_head` (146-148) | Same helper | `\`cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null\`.strip` |

**Divergences from spike driver that Step 5 must apply:**

1. **Don't wipe on start** — `prepare_workspace` in the spike `rm_rf`s any existing directory (line 64). Step 5 must not, because retries and continuation need workspace state intact.
2. **Raise-on-fail stops iteration, but spike raises** — `execute_revision` in the spike raises on non-zero exit (line 120-121). Step 5 sets `status: :failed` and `break`s instead (per plan pseudocode line 330 `break if revision.failed?`).
3. **Metrics structure** — spike writes a combined JSON file for the whole run. Step 5 stores `{wall_seconds, exit_code, git_sha}` per-revision in `revision.metrics` jsonb (plan lines 364-368).
4. **`chdir:` arg** — spike passes `chdir: SPIKE_DIR` to `system`. In the Rails app, `bin/roast` already `cd`s to repo root (line 16), so the job doesn't need `chdir:`. But the invocation must use absolute paths for both the script and the workflow file — `Rails.root.join("bin/roast").to_s` / `Rails.root.join("lib/roast/revision_workflow.rb").to_s`.
5. **Status broadcasting** — spike only `puts`. Step 5 emits events; Step 6 subscribes them to Turbo.

### 4. Event bus — planned additions for Step 5 + 6

From `docs/02-architecture/02-layer-integration.md:37-52`:

```
"revision.started"         payload: { revision_id: }
"revision.completed"       payload: { revision_id:, git_sha: }
"revision.failed"          payload: { revision_id:, error: }
"instruction.completed"    payload: { instruction_id: }
"instruction.failed"       payload: { instruction_id: }
```

**Subscribers (Step 6)** go in `config/initializers/event_subscribers.rb`:
- `instruction.requested` → `ExecuteInstructionJob.perform_later(instruction_id)` (this is what wires Step 4's notification to Step 5's job).
- `revision.*` → `Turbo::StreamsChannel.broadcast_replace_to(revision.project, target: "revision_#{revision.id}", partial: "revisions/revision", locals: { revision: revision })`.
- `instruction.completed / failed` → `ChatFollowUpJob.perform_later(instruction_id, event:)`.

**Open question**: should the `instruction.requested` → enqueue subscriber ship as part of Step 5 or Step 6? Plan text puts it under Step 4's bullet 5 (line 304) but Step 4 deliberately skipped it. Step 5's job is the subscriber's counterparty — practical choice is to land both in Step 5 (the job + the `instruction.requested` subscriber), leave the `revision.*` broadcasters for Step 6 which also owns the `revisions/_revision.html.erb` partial.

### 5. Solid Queue concretes

Findings from up-to-date docs (Solid Queue 1.x, Rails 8 default):

- **No per-job or per-queue timeout.** Only `shutdown_timeout` (default 5s) — process-level grace on SIGTERM. Step 5's no-hard-timeout decision is fine for PoC; Step 7 can revisit with `Timeout.timeout` wrapping the `system()` call if a revision gets stuck.

- **SIGTERM propagation to child process is NOT automatic.** If `bin/jobs` receives SIGTERM mid-subprocess, the Ruby worker gets the signal but `system(env, *args)` child does NOT unless the job explicitly traps and forwards. Plan punts cancel/SIGTERM to Phase 2.5 (`docs/03-plans/01-phase-2-poc-generator-app.md:49`) — acceptable trade-off, but note the behavior: if the worker is killed, the subprocess keeps running, then the `Process.wait`'s host is gone and the child becomes orphaned.

- **Job state after worker death**: Solid Queue uses heartbeats (`process_heartbeat_interval` default 60s, `process_alive_threshold` default 5min). Stale claims become `SolidQueue::FailedExecution`. Since we set `retry_on … attempts: 1` = no auto-retry, the job won't re-run — manual retry via Solid Queue dashboard or `SolidQueue::FailedExecution#retry`.

- **Concurrency control choices** (relevant to D4/D5 below):
  - **(A)** Add a dedicated worker pool + queue in `config/queue.yml`: `workers: [{queues: [generation], threads: 1, processes: 1}, {queues: [default, mailers], threads: 3, processes: 1}]` — strict isolation; other queues keep moving even if `generation` is stuck.
  - **(B)** Keep single pool, use `limits_concurrency to: 1, key: …, duration: N.minutes` DSL — simpler config; duration bound is a correctness footgun (must exceed longest expected run).
  - **(C)** Hybrid: single pool + `queue_as :generation` + `limits_concurrency` with a project-scoped key.

  Plan pseudocode (line 386) says "concurrency 1" without specifying mechanism. Memory/pattern-wise the codebase hasn't used `limits_concurrency` yet. See Open Questions.

### 6. Test strategy — patterns to reuse

**Pattern A: notification assertions** (`test/tools/start_generation_test.rb:62-77, 92-110`):
```ruby
payloads = []
subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") do |*, p|
  payloads << p
end
# ... exercise
assert_equal 1, payloads.size
assert_equal instruction.id, payloads.first[:instruction_id]
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
```

**Pattern B: stubbing a constant's class method** (`test/tools/start_generation_test.rb:20-28`):
```ruby
original = CreatePlan.method(:call)
CreatePlan.define_singleton_method(:call) { |**kwargs| result_or_proc.respond_to?(:call) ? result_or_proc.call(**kwargs) : result_or_proc }
yield
ensure
  CreatePlan.define_singleton_method(:call, original) if original
```
Same shape works for stubbing `ExecuteInstructionJob`'s helpers or the bare `system()` call at module scope if the job is refactored to route through a seam.

**Pattern C: `assert_enqueued_with(job:, args: [...])`** (used in `test/controllers/projects_controller_test.rb`) — drop-in for asserting that `ChatRespondJob`-like enqueues happen.

**Pattern D: `assert_broadcasts` / `broadcasts(stream)`** — used in `test/models/message_test.rb`. Directly applicable once Step 6 adds the revision-status subscriber.

**Gap**: there is currently NO test scaffolding for a job that shells out to a subprocess. `execute_revision` is the first. The job must be decomposed so `system()` can be stubbed (e.g., a method seam `run_roast_subprocess(env, args)` that returns `[exit_code, wall_seconds]`; tests stub that seam; one integration test exercises the real subprocess with the smoke workflow to guard against shell-injection regressions).

### 7. Integration-test target (Step 7 context, but affects Step 5 seams)

`docs/03-plans/01-phase-2-poc-generator-app.md:432-437` specifies the E2E test that Step 7 will write:
- Stub `chat.complete` (chat LLM) → deterministic `StartGeneration` call.
- Stub `CreatePlan.call` → `test/fixtures/plans/todo_list.rb` (planned fixture, not present today).
- `ExecuteInstructionJob.perform_now` — **NOT stubbed** (real subprocess, 8+ minute wall time).
- Assert `instruction.completed?`, `project.revisions.count == 3`, `git log` has 3+1 commits in workspace, `rails test` in workspace green.
- Budget: `wall_time < 900s` (15 min).

**Implication for Step 5's job design**: ensure there IS a clean seam so unit tests stub the subprocess while the integration test can run it for real. A method `run_roast_subprocess(env, args)` (or similar) is one shape; another is passing an `executor:` keyword with a default. Either works — choose what tests are easiest to read with.

### 8. CLI mirror — `bin/generate`

Plan line 438-441 specifies:
- `bin/generate full --prompt "..."` — creates project + forces `StartGeneration` (stubs same as E2E test) + runs job synchronously.
- `bin/generate respond --project-id=N` — manually triggers `ChatRespondJob`.
- `bin/generate execute --instruction-id=N` — synchronous `ExecuteInstructionJob` (debug without worker).

**Not present today** (no `bin/generate` script). Scope-wise this is Step 7, but the `execute` subcommand is just `ExecuteInstructionJob.perform_now(id)` with Bundler bootstrap — can be dropped in alongside Step 5 for manual testing.

## Code References

- `docs/03-plans/01-phase-2-poc-generator-app.md:310-389` — Step 5 pseudocode, DoD, open questions
- `docs/03-plans/01-phase-2-poc-generator-app.md:151-155` — three ENV gotchas (wrapper, frum, bundler env)
- `docs/03-plans/01-phase-2-poc-generator-app.md:454-455` — workspace path migratability, `rails new` `.ruby-version` conflict
- `docs/02-architecture/01-workflows-and-decisions.md:125-135` — W2.3 agent prompt invariants (**load-bearing for Step 5's workspace preconditions**)
- `docs/02-architecture/01-workflows-and-decisions.md:259-317` — Roast DSL example + spike gotchas
- `docs/02-architecture/02-layer-integration.md:37-52` — event names and payloads
- `docs/02-architecture/02-layer-integration.md:163-179` — Turbo Streams broadcasting from workflows pattern
- `docs/02-architecture/02-layer-integration.md:183-207` — guidelines (subscribers only enqueue/broadcast; HTTP only save/enqueue; notifications synchronous)
- `docs/01-vision/02-user-journey.md:378-409` — ExecuteRevisionJob detail
- `spikes/roast/findings.md:152-159` — three ENV gotchas (canonical)
- `spikes/roast/new_app_driver.rb:62-148` — orchestration that becomes `ExecuteInstructionJob`
- `lib/roast/revision_workflow.rb:21-24` — ENV contract (`REVISION_WORKSPACE`, `CLAUDE_MODEL`)
- `lib/roast/verify_revision.rb:58-65` — `with_clean_bundler_env` (third ENV leak mitigation)
- `bin/roast:9-25` — wrapper hygiene (unset ANTHROPIC_*, pin PATH via `.ruby-version`)
- `app/tools/start_generation.rb:48-51` — `instruction.requested` instrumentation
- `app/models/project.rb:8-10` — `workspace_path` method (relative, derived from `id`)
- `app/models/revision.rb:6-11` — `status` enum
- `app/models/instruction.rb:6-13` — `phase` enum
- `db/schema.rb:112-130` — `revisions` table with Step 4 columns (`prompt`, `started_at`, `finished_at`, `metrics`)
- `db/migrate/20260418172451_add_step4_columns_to_instructions_and_revisions.rb` — Step 4 schema reconciliation
- `config/queue.yml:1-19` — current Solid Queue pool (single, all queues)
- `config/cable.yml:1-7` — solid_cable in dev (per memory `project_dev_cable_solid`)
- `.gitignore:24-29` — `/storage/*` already excludes `storage/workspaces/`
- `test/tools/start_generation_test.rb:62-110` — notification + error-path test patterns to reuse
- `tmp/smoke_workflow.sh` + `lib/roast/smoke_workflow.rb` — reusable "is the Roast pipeline healthy?" guard

## Architecture Documentation

### Workspace lifecycle (from W2.3.1 invariant + Step 5 plan)

```
Instruction N for Project P
    │
    ▼
ExecuteInstructionJob#perform(instruction.id)
    │
    ├── prepare_workspace(project, workspace)
    │   └── FileUtils.mkdir_p(workspace_root)  — idempotent; does NOT wipe
    │
    ├── rails_new(project, workspace) unless File.exist?(Gemfile)
    │   └── cd workspace_root && rails new <name> --css tailwind --database sqlite3
    │       --skip-jbuilder --skip-kamal --skip-ci
    │   └── (Rails 8 also does `git init` + initial commit)
    │
    ├── init_docs_baseline(workspace) unless File.exist?(docs/)
    │   └── docs/{architecture,conventions,domain,revision_notes}.md seeded empty
    │   └── git add -A && git commit -m 'docs: scaffolding baseline'
    │
    └── foreach revision in instruction.revisions.order(:position):
         └── execute_revision(revision, workspace)
             ├── revision.update!(status: :generating, started_at: now)
             ├── instrument("revision.started", revision_id:)
             ├── system({REVISION_WORKSPACE, CLAUDE_MODEL}, bin/roast, revision_workflow.rb, --, revision_id=…, revision_summary=…, revision_prompt=…)
             ├── if ok: update!(status: :completed, finished_at:, git_sha:, metrics:) + instrument("revision.completed", git_sha:)
             ├── else:   update!(status: :failed,    finished_at:, metrics:)          + instrument("revision.failed", error:)
             └── break if failed

    instruction.update!(phase: all(completed) ? :completed : :failed)
    instrument("instruction.#{completed|failed}", instruction_id:)
```

### Event flow (Step 4 → Step 5 → Step 6)

```
User msg → ChatRespondJob → agent.complete
                              ├── StartGeneration(intent, clarifications).execute
                              │     ├── CreatePlan.call → PlanSchema JSON
                              │     ├── transaction { Instruction + Revisions create! }
                              │     └── instrument("instruction.requested", instruction_id:)  ←── Step 4 SHIPPED
                              │                                              │
                              └── SuggestPrompts(prompts).execute             │
                                    └── broadcast_replace_to suggestions     │
                                                                             ▼
               event_subscribers.rb subscribes                  ExecuteInstructionJob.perform_later(id)  ←── STEP 5
                                                                             │
                                                                             ▼
                                                                 (runs in :generation queue, concurrency 1)
                                                                             │
                                                                             ├── instrument("revision.started") ←── STEP 5 emits
                                                                             ├── instrument("revision.completed") ←── STEP 5 emits
                                                                             ├── instrument("revision.failed")    ←── STEP 5 emits
                                                                             └── instrument("instruction.{completed,failed}") ←── STEP 5 emits

                            ┌────────────────────────────────────────────────┘
                            ▼
  config/initializers/event_subscribers.rb (Step 5 or Step 6):
    revision.*     → Turbo::StreamsChannel.broadcast_replace_to(project, target: "revision_#{id}", partial: "revisions/revision")  ←── STEP 6 broadcasters
    instruction.*  → ChatFollowUpJob.perform_later(instruction_id, event:)  ←── STEP 6 follow-up
```

### Concurrency stance

- **Queue: `:generation`, concurrency 1** (plan line 386) — serialises generations across the whole deployment (matches "one active instruction per project" from `docs/01-vision/02-user-journey.md` "Parallel instructions" section).
- **Chat: `:default`, threads 3** — chat responses don't block each other or generation.
- **Retry: `attempts: 1`** — effectively "don't retry". `retry_on StandardError, wait: :polynomially_longer, attempts: 1` declares retry shape but never actually retries (attempts=1 is the initial try); using `discard_on StandardError` would be clearer if the intent is to never retry even on transient error. See Open Questions D3.

### ENV hygiene summary (canonical — do not deviate)

1. `bin/roast` wrapper unsets `ANTHROPIC_*` and pins PATH to `$HOME/.frum/versions/$(.ruby-version)/bin`.
2. `VerifyRevision.with_clean_bundler_env` unsets `BUNDLE*/BUNDLER*/RUBYOPT` before shelling from Roast workflow to workspace `bin/rails`.
3. Step 5's job passes env explicitly via `system({"REVISION_WORKSPACE" => …, "CLAUDE_MODEL" => …}, …)` — Ruby's `system` with an env hash does NOT merge with the parent ENV, it **adds to it**. So parent-process `ANTHROPIC_*` (if any) would still leak unless the wrapper unsets them — which it does. The job does not need to pre-clean the environment itself.

## Historical Context (from `thoughts/`)

- `./thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md:7` — **"No subscriber is wired in Step 4. ExecuteInstructionJob stays absent. The notification fires into the void — deliberately, so Step 5 can shape it from scratch without inheriting a stub."** Load-bearing decision that defines Step 5's scope.
- `./thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md:830` — "If Step 5 needs cross-tool state, inject via a shared context object — not via Current." Rules out `Current.project` in the job too; pass `project_id` → lookup explicitly.
- `./thoughts/shared/research/2026-04-18/phase-2-step-4-research.md:54` — notes `Project#workspace_initialized?` method doesn't exist yet. Step 5 must decide: derive from files (`File.exist?(Gemfile)`) or add a boolean column / status machine.
- `./thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md:38` — "**no `Current.project`**" — precedent across Step 3/4/5.
- `./thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` — patterns around `Chat#complete` / `on_new_message` / tool_calls persistence that indirectly affect Step 6's `ChatFollowUpJob` (not Step 5 directly).

## Open Questions

Numbered for tracking. Each has a recommended default; Step 5 implementation should either confirm or override.

### D1. `Project#workspace_initialized?` — method or column?

**Context**: plan pseudocode (`docs/03-plans/01-phase-2-poc-generator-app.md:324`) says `prepare_workspace(project, workspace) unless project.workspace_initialized?`. No such method exists today.

**Options**:
- **(a)** File-derived: `def workspace_initialized?; File.exist?(File.join(Rails.root, workspace_path, "Gemfile")); end` — zero schema change, always reflects reality.
- **(b)** Boolean column `workspaces.initialized_at:datetime` + update in `init_docs_baseline` — explicit, but can drift from disk.
- **(c)** Conflate with `instructions.count > 0 && instructions.first.revisions.any?(&:completed?)` — too indirect.

**Default recommendation**: (a). The plan already uses file-existence guards for `rails_new` and `init_docs_baseline` (lines 325-326) — staying consistent avoids the drift risk and keeps retries/manual repair idempotent.

### D2. Where does the `instruction.requested` → `ExecuteInstructionJob.perform_later` subscriber live?

**Context**: Step 5 is the natural place (the job is the counterparty). Step 6 is where plan's `event_subscribers.rb` is formalised. Plan text (`docs/03-plans/01-phase-2-poc-generator-app.md:304`) lists the subscriber under Step 4 bullet 5, which was deferred.

**Options**:
- **(a)** Ship the `instruction.requested` subscriber in Step 5 (`config/initializers/event_subscribers.rb` with only this one entry); Step 6 extends with `revision.*` and `instruction.{completed,failed}`.
- **(b)** Ship ALL subscribers in Step 5; Step 6 is only the partial + `ChatFollowUpJob`.
- **(c)** Call `ExecuteInstructionJob.perform_later` directly from `StartGeneration#execute` instead of via the bus, keeping the notification purely observational.

**Default recommendation**: (a). Keeps Step 5 self-contained (job + its enqueue trigger). `revision.*` broadcasters need the `revisions/_revision.html.erb` partial which is Step 6 scope. Option (c) couples the tool to the job and breaks the canonical "tool emits, subscriber routes" pattern from `docs/02-architecture/02-layer-integration.md`.

### D3. Retry policy — `retry_on attempts: 1`, `discard_on`, or nothing?

**Context**: plan pseudocode (`docs/03-plans/01-phase-2-poc-generator-app.md:385`) says `retry_on StandardError, wait: :polynomially_longer, attempts: 1` with the rationale "we don't auto-retry generation — after a fail the user decides." But `attempts: 1` in ActiveJob means "try 1 time total" — i.e., run once and give up. The `retry_on` block with `attempts: 1` is effectively a no-op wrapped in an error handler.

**Options**:
- **(a)** Literally plan text: `retry_on StandardError, wait: :polynomially_longer, attempts: 1` (intent = "do nothing on error").
- **(b)** `discard_on StandardError` — unambiguously says "don't retry, don't even log as failed execution". Risky: loses `SolidQueue::FailedExecution` row, making manual retry harder.
- **(c)** Omit both — default ActiveJob behaviour is "no retry, record as failed execution". Standard and simplest.
- **(d)** `retry_on SpecificTransientError, attempts: 3` for known-transient errors (e.g., `Errno::EAGAIN` from `system()`); everything else: no retry.

**Default recommendation**: (c). Aligns with the intent ("user decides after fail") without misleading code. `SolidQueue::FailedExecution` is visible in the dashboard, manual retry via `failed.retry` is trivial. Reserve (d) only if transient errors become frequent.

### D4. Concurrency mechanism — separate worker, `limits_concurrency`, or both?

**Context**: plan says "concurrency 1" on `generation` queue (line 386). Current `config/queue.yml` has a single pool with `queues: "*"`.

**Options**:
- **(a)** Add a dedicated worker pool for `generation`:
  ```yaml
  workers:
    - queues: [generation]
      threads: 1
      processes: 1
      polling_interval: 1
    - queues: [default, mailers, "*"]
      threads: 3
      processes: 1
      polling_interval: 0.1
  ```
  Strict isolation — generation can't starve other queues, other queues can't starve generation.
- **(b)** Keep single pool, add `limits_concurrency to: 1, key: ->(id) { "generation" }, duration: 30.minutes` on `ExecuteInstructionJob`. Simpler config; the `duration` is a footgun if the real job can exceed it.
- **(c)** Both — defense in depth, but the `duration:` becomes the bounding risk.

**Default recommendation**: (a). The config is 5 lines; the risk of `limits_concurrency` `duration:` drift on a 30-min subprocess is real (Solid Queue docs: the semaphore expires after `duration:` even if the job still holds it). A dedicated pool with `threads: 1, processes: 1` is the simplest correct answer.

**Sub-question**: should the dedicated `generation` worker run in a **separate process** from `web`? Currently `Procfile.dev:3` has `worker: bin/jobs` which picks up all queues. For production isolation we'd want two worker processes; for dev a single `bin/jobs` reading both pools in `config/queue.yml` is fine (the pool's own concurrency limits apply).

### D5. `prepare_workspace` — must it handle leftover state from a failed previous run?

**Context**: the spike's `prepare_workspace` wipes the directory (`FileUtils.rm_rf`). Step 5 must not wipe (retries + continuation). But what if the previous run failed **between `rails_new` and the first revision's commit**? Then `Gemfile` exists (so `rails_new` is skipped) but git history may be missing or in a broken state.

**Options**:
- **(a)** Trust file-existence guards + the Rails 8 convention that `rails new` creates an initial commit (`rails new` invokes `git init` + commits). If `Gemfile` exists, it's from a prior `rails new`, which also created git history.
- **(b)** Additionally check `File.exist?(File.join(workspace, ".git/HEAD"))` and re-run scaffolding baseline if not.
- **(c)** Add a `workspace_initialized?` boolean column (D1 option (b)) flipped to true only after `init_docs_baseline` commits successfully.

**Default recommendation**: (a) for PoC. Edge case (interruption between `rails new` and baseline commit) is rare; if observed, promote to (c) at that point. Hard-delete recovery is a manual `rm -rf storage/workspaces/<id>` step — acceptable dev-mode affordance.

### D6. `rails_new` invocation — how to isolate from generator's Ruby/Gemfile?

**Context**: `docs/03-plans/01-phase-2-poc-generator-app.md:455` flags: "`rails new` in subprocess may inherit frum shim — `VerifyRevision.with_clean_bundler_env` should handle it (verified in the spike)".

**Options**:
- **(a)** Call `rails new` inside `VerifyRevision.with_clean_bundler_env { system("cd … && rails new …") }`. The workspace gets a clean env so its own `bundle install` (which `rails new` runs) sees only the workspace's forthcoming Gemfile.
- **(b)** Use `Bundler.with_unbundled_env { … }` explicitly (same effect as (a), more idiomatic).
- **(c)** Shell to `bin/roast` even for `rails_new` (overkill — `bin/roast` adds Roast-specific unsets we don't need).

**Default recommendation**: (b) — `Bundler.with_unbundled_env` is the Rails-idiomatic form. Extract the same helper `VerifyRevision.with_clean_bundler_env` if dropping a dependency on Bundler directly is preferred; functionally equivalent for our purposes.

**Related**: the generator's `.ruby-version` is `4.0.2`. `rails new` in the subprocess will create a workspace with its OWN `.ruby-version` (Rails 8 default — check). If the subprocess inherits the frum shim resolution for `4.0.2`, the workspace's Gemfile will install gems under 4.0, and `bin/roast` wrapper pinning PATH to `4.0.2` means verification also runs under 4.0. This matches the spike's working configuration. The only risk is if Rails 8 changes its `rails new --ruby-version` default (unlikely mid-8.x).

### D7. `CLAUDE_MODEL` default — `sonnet` or configurable per-Revision?

**Context**: plan pseudocode hardcodes `"sonnet"` with `ENV.fetch("CLAUDE_MODEL", "sonnet")` override. The spike used `sonnet` for the todo-list run (findings.md:141). Haiku is 10× cheaper, Sonnet gives better Rails code.

**Options**:
- **(a)** Hardcode `sonnet` as plan specifies (via ENV override). Simple, matches spike.
- **(b)** Add `revision.model:string` column; let `CreatePlan` choose per-revision (e.g., Haiku for scaffolding, Sonnet for logic). Premature — no evidence yet that per-revision model selection helps.
- **(c)** Configurable via `Rails.configuration.x.generator.claude_model` in `config/application.rb`. Useful for tests (override to `haiku` for cheaper CI runs). Optional polish.

**Default recommendation**: (a) with (c) as a 5-minute follow-up if integration tests burn through budget.

### D8. CLI mirror (`bin/generate execute`) scope — alongside Step 5 or deferred to Step 7?

**Context**: plan puts CLI mirror in Step 7 (line 438). But `bin/generate execute --instruction-id=N` is just `ExecuteInstructionJob.perform_now(id)` with Bundler bootstrap. Useful for manual DoD verification of Step 5 without running the worker.

**Options**:
- **(a)** Ship just the `execute` subcommand in Step 5 (or a standalone `bin/execute-instruction`). `full` and `respond` wait for Step 7.
- **(b)** Defer entirely to Step 7 as written; use `rails runner` one-liner for manual testing in the meantime.

**Default recommendation**: (a). A ~20-line script reduces the Step 5 DoD to one command and is the natural shape for debugging the job outside the worker. Could be a single file `bin/execute-instruction` with just `require "./config/environment"; ExecuteInstructionJob.perform_now(ARGV[0].to_i)`.

### D9. Integration test seam for `system()`

**Context**: Step 7's E2E test runs the real subprocess; unit tests must not. Needs a stubbable seam inside `ExecuteInstructionJob`.

**Options**:
- **(a)** Extract `run_roast_subprocess(env, args) → [ok?, exit_code, wall_seconds]` as a private method; tests stub it.
- **(b)** Inject an `executor:` keyword arg on `perform` with a default callable; tests pass their own.
- **(c)** No seam — stub `Kernel#system` globally in each test (ugly, leaks state).

**Default recommendation**: (a). Private method seam is the simplest Ruby idiom, aligns with the `CreatePlan.define_singleton_method(:call)` pattern used in `StartGeneration` tests. No public API pollution.

### D10. `.gitignore` entry for `storage/workspaces/` — explicit or implicit?

**Context**: `.gitignore:25` already has `/storage/*` + exception for `.keep`. Transitively ignores `storage/workspaces/`.

**Options**:
- **(a)** Leave as-is — covered by `/storage/*`.
- **(b)** Add explicit `/storage/workspaces/` comment + rule for clarity.

**Default recommendation**: (a). Adding redundant rules is noise. A single comment above `/storage/*` noting "also covers storage/workspaces/ for generated apps" is optional polish.

### D11. Roast version compatibility — pinned but stale?

**Context**: `Gemfile:47` has `gem "roast-ai", "~> 1.1"`. Spike proven at 1.1.0. `.ruby-version` = `4.0.2`. Roast 1.x requires Ruby 3.3+.

**No blocker**, but before Step 5 runs the first end-to-end ExecuteInstructionJob for real: run `bundle outdated roast-ai` to confirm no 1.x security fix has shipped. Also check that `bundle info roast-ai` resolves — the `bin/roast` wrapper doesn't help here; this is the generator-side Gemfile.

## Related Research

- `./thoughts/shared/research/2026-04-18/phase-2-step-4-research.md` — Step 4 codebase state (predecessor to this doc; Instruction/Revision schema gaps, tool infrastructure maps).
- `./thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` — RubyLLM 1.14.1 canonical patterns (indirectly relevant to Step 6's `ChatFollowUpJob`).
- `./thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md` — Step 4 plan; the `instruction.requested` notification lives here.
- `./thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md` — Step 3 plan; `no Current.project` precedent; streaming chat baseline.
- `./thoughts/shared/plans/2026-04-19/phase-2-step-4-refinement-plan-schema.md` — PlanSchema refinement; `with_schema` adoption.
- `./thoughts/shared/plans/2026-04-19/ruby-llm-finding-3-generator-agent.md` — `GeneratorAgent` extraction; tools attached per instance, project via ctor.
- `spikes/roast/findings.md` — Phase 1 closure; three ENV gotchas + metrics from the full pipeline run.

## Next Steps

Once Step 5 planning adopts defaults for D1-D11 (or chooses alternates), the implementation splits naturally into 3 atomic commits:

1. **`ExecuteInstructionJob` core + helpers** — job class with `system()` seam; `rails_new / init_docs_baseline / git_head / run_roast_subprocess` helpers; unit tests stubbing the seam; no enqueue wiring yet.
2. **Subscriber + queue config** — `config/initializers/event_subscribers.rb` with the `instruction.requested → perform_later` subscriber; `config/queue.yml` update for `:generation` queue; `ApplicationJob` configured with `queue_as :default` (keep chat on default) or keep global default and set `queue_as :generation` on `ExecuteInstructionJob` only. Tests assert `assert_enqueued_with(job: ExecuteInstructionJob, args: [id])` when the notification fires.
3. **Manual DoD + debug CLI** — `bin/execute-instruction`; README snippet for running the job from the console; one test that creates an `Instruction` with a stubbed `system()` seam and asserts all revisions transition to completed with metrics populated.

Step 6 then adds the `revision.*` broadcasters, the `revisions/_revision.html.erb` partial, the `ChatFollowUpJob`, and `instruction.{completed,failed}` subscribers.

Step 7 adds `bin/generate full --prompt` and the 15-minute budgeted E2E integration test. The current Step 5 answers D9 with the method seam, which makes both straightforward.
