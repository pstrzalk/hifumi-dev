---
date: 2026-04-20
planner: Paweł Strzałkowski
status: draft
tags: [phase-2, step-5, execute-instruction-job, roast, solid-queue]
supersedes_sketch_in: docs/03-plans/01-phase-2-poc-generator-app.md:310-389
research: thoughts/shared/research/2026-04-20/phase-2-step-5-execute-instruction-job.md
---

# Phase 2 Step 5 — `ExecuteInstructionJob` + Roast integration

## Overview

Move `spikes/roast/new_app_driver.rb`'s orchestration into a Solid Queue job. The job consumes `instruction.requested` events (emitted by `StartGeneration` but currently firing into the void), prepares the project's workspace once via `rails new` + docs baseline, then loops over `instruction.revisions.order(:position)` shelling out `bin/roast lib/roast/revision_workflow.rb -- …` per revision, persisting `status / started_at / finished_at / git_sha / metrics` to the DB and emitting `revision.*` + `instruction.{completed,failed}` events for Step 6 to broadcast.

## Current State Analysis

- Step 4 closed on `d485c8c` (2026-04-19). `StartGeneration#execute` (`app/tools/start_generation.rb:48-51`) persists `Instruction` + chained `Revision` rows and fires `instruction.requested`. **No subscriber exists** — deliberately left for Step 5 to shape from scratch.
- Roast pipeline bootable in-app: `bin/roast`, `bin/roast-openrouter`, `lib/roast/revision_workflow.rb`, `lib/roast/verify_revision.rb` copied 1:1 from the spike (Step 1, commit `61667ee`).
- DB schema has every column Step 5 needs: `revisions { prompt, started_at, finished_at, metrics (json), git_sha, status enum }`; `instructions.phase` enum includes `implementing / completed / failed`. No migrations needed.
- `StartGeneration` writes `position: i` (0-indexed), sets `phase: :implementing`. Step 5's job transitions `implementing → completed | failed`.
- `config/queue.yml` has a single worker pool (`queues: "*"`, threads 3, processes 1). No `generation` queue yet. `Procfile.dev:3` starts one `bin/jobs` worker.
- `ApplicationJob` is vanilla template. `ChatRespondJob` uses `queue_as :default`.
- `Project#workspace_path` returns `"storage/workspaces/#{id}"` — relative, method-derived (no column). **No `workspace_initialized?` method.**
- `/storage/*` in `.gitignore` transitively covers `storage/workspaces/`. No change needed.
- Test patterns exist: `test/tools/start_generation_test.rb:62-77` (notification capture + unsubscribe), `test/jobs/chat_respond_job_test.rb` (job test structure + stubbing Chat methods via `class_eval`).
- **Gotcha**: `rails new` requires a valid Ruby constant name. `rails new 42` fails because `"42".classify` produces an invalid module name. Workspace path must be prefixed (`storage/workspaces/project_42`). Two tests pin the current format and need updating (`test/models/project_test.rb:16`, `test/controllers/projects_controller_test.rb:39-48`).

## Desired End State

After Step 5:

1. `ExecuteInstructionJob` exists, takes `instruction_id`, performs the end-to-end pipeline with `bin/roast`.
2. `instruction.requested` → `ExecuteInstructionJob.perform_later` via `config/initializers/event_subscribers.rb` (single subscriber; Step 6 extends with `revision.*` broadcasters).
3. `config/queue.yml` has a dedicated `generation` worker pool (threads: 1, processes: 1) separate from `[default, mailers]` — strict isolation, no `limits_concurrency` DSL.
4. `bin/execute-instruction <id>` runs the job synchronously for manual debugging (calls `perform_now`).
5. All five events emitted with documented payload shapes: `revision.started`, `revision.completed (git_sha:)`, `revision.failed (error:)`, `instruction.completed`, `instruction.failed`.
6. Full test suite green. Subprocess is stubbed in unit tests via a private method seam (`run_roast_subprocess`); a DoD manual-run verifies the real pipeline end-to-end.
7. ENV variables read by the Roast workflow renamed to `RAILS_APP_GENERATOR_WORKSPACE` / `RAILS_APP_GENERATOR_MODEL` so they don't collide with other Rails apps the user runs locally.

### Verification

- `bin/rails test` green.
- `bin/execute-instruction <id>` on a hand-crafted `Instruction` with one real revision produces a Rails app in `storage/workspaces/project_<id>/` with 2 commits (`docs: scaffolding baseline` + revision summary), `Revision.reload.completed?` true, `git_sha` populated, `metrics[:wall_seconds] > 0`, `metrics[:exit_code] == 0`.

### Key Discoveries

- `bin/roast:9-25` — wrapper unsets `ANTHROPIC_*` and pins `PATH` to frum Ruby 4.0.2. Using `bin/roast` means the Claude CLI uses subscription OAuth. Do NOT call `bundle exec roast` directly (breaks 3 ENV gotchas from Phase 1 — `spikes/roast/findings.md:152-159`).
- `lib/roast/revision_workflow.rb:21-24` — ENV contract reads `REVISION_WORKSPACE` and `CLAUDE_MODEL`. Both renamed in Phase 1.
- `lib/roast/verify_revision.rb:58-65` — `with_clean_bundler_env` handles the third ENV leak when Roast's ruby step shells into the workspace. Not touched in Step 5.
- `bin/roast-openrouter:9-14` — paid per-token fallback. Unchanged by this plan.
- `db/schema.rb:112-130` — Revision columns align with `execute_revision`'s writes. No migration.
- `app/tools/start_generation.rb:27-46` — writes `position: i` (0-indexed) and chains `parent:` through the loop. Job reads revisions via `order(:position)` and doesn't assume an index base.

## What We're NOT Doing

- `revision.*` broadcasters + `revisions/_revision.html.erb` partial → **Step 6**.
- `instruction.{completed,failed}` → `ChatFollowUpJob` subscribers → **Step 6**.
- `SuggestPrompts` cards tied to instruction-complete → **Step 6**.
- `bin/generate full --prompt "…"` + `bin/generate respond` → **Step 7** (only the `execute` equivalent ships here, as `bin/execute-instruction`).
- Integration test with real subprocess → **Step 7** (budget 15 min; Step 5's unit tests stub the seam).
- Hard timeout on `system()` → **Step 7 if observed**. Spike's worst was 226s/revision.
- Cancellation / SIGTERM forwarding to the subprocess → **Phase 2.5 or Phase 3**. If the worker dies mid-revision, the subprocess orphans and the Revision stays in `generating` — acceptable for PoC; manual cleanup via `git reset --hard` + `Revision#update!(status: :failed)`.
- `retry_on` / `discard_on` / `limits_concurrency` DSL → none used. Default ActiveJob behavior: failure → `SolidQueue::FailedExecution` row, manual retry.
- Explicit `.gitignore` entry for `storage/workspaces/` → `/storage/*` already covers it.

## Implementation Approach

Five atomic commits. Test suite stays green after each.

1. **Rename ENV vars** (pure rename, no behavior change).
2. **`ExecuteInstructionJob` + `Project` touchpoints** (workspace path prefix, `workspace_initialized?`, job class, unit tests — `queue_as :generation` refers to a pool not yet declared; Solid Queue accepts this without error).
3. **Queue pool + event subscriber** (declares the `generation` pool; wires `instruction.requested` → job).
4. **`bin/execute-instruction`** (debug CLI).
5. **DoD run** (manual, documented — create Instruction, call CLI, verify workspace).

Phase ordering is strict: 1 → 2 (tests reference new env names), 2 → 3 (subscriber needs the job to exist), 3 → 4 is independent but kept last so CLI exists after the production path works, 5 is the final validation.

---

## Phase 1: Rename Roast ENV variables

### Commit
`phase 2 step 5 (1/5): rename Roast ENV vars to RAILS_APP_GENERATOR_*`

### Overview

`REVISION_WORKSPACE` → `RAILS_APP_GENERATOR_WORKSPACE`; `CLAUDE_MODEL` → `RAILS_APP_GENERATOR_MODEL`. Pure rename. Touches only the Roast workflow file and the smoke shell. No behavior change.

### Changes Required

#### 1. `lib/roast/revision_workflow.rb`

**Changes**: update the two `ENV.fetch` calls (lines 21, 24) and the usage comment (lines 10-16). No other changes.

```ruby
# Run:
#   RAILS_APP_GENERATOR_WORKSPACE=/path/to/app bundle exec roast revision_workflow.rb -- \
#     revision_id=1 \
#     revision_summary="Add Todo model" \
#     revision_prompt="Create Todo model with title, body, done. Migration + tests."
#
# Model override via ENV:
#   RAILS_APP_GENERATOR_MODEL=haiku RAILS_APP_GENERATOR_WORKSPACE=... bundle exec roast ...

WORKSPACE = ENV.fetch("RAILS_APP_GENERATOR_WORKSPACE") do
  abort("RAILS_APP_GENERATOR_WORKSPACE env var is required (path to Rails workspace).")
end
CLAUDE_MODEL = ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet")
```

Keep the constant named `CLAUDE_MODEL` in the Ruby code (it's still the model for Claude CLI). The ENV name is the only thing that changes.

#### 2. `docs/02-architecture/01-workflows-and-decisions.md`

**Changes**: the architecture canon references the old env names in a Roast DSL pseudocode block and an ENV hygiene line. Update:

- Line 237 (comment): `# Workspace via ENV: RAILS_APP_GENERATOR_WORKSPACE=/path/to/project`
- Line 239: `WORKSPACE = ENV.fetch("RAILS_APP_GENERATOR_WORKSPACE")`
- Line 240: `CLAUDE_MODEL = ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet")` (Ruby const stays `CLAUDE_MODEL` — it's still the model used by Claude CLI; only the ENV name changes)
- Line 317: ENV hygiene sentence lists `RAILS_APP_GENERATOR_WORKSPACE`, `RAILS_APP_GENERATOR_MODEL` instead of the old names.

**Leave alone**: `spikes/roast/*` (frozen reference implementation per CLAUDE.md), `docs/03-plans/01-phase-2-poc-generator-app.md` (historical plan snapshot; its pseudocode doesn't need to stay in sync with runtime code), `tmp/smoke_workflow.sh` (doesn't set these envs — just shells to `bin/roast lib/roast/smoke_workflow.rb`).

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` green.
- [x] `grep -rn 'REVISION_WORKSPACE\|CLAUDE_MODEL' lib/ app/ bin/ config/ docs/02-architecture/` returns empty (no leftover references in runtime code or architectural canon).
- [x] `grep -rn 'RAILS_APP_GENERATOR_WORKSPACE\|RAILS_APP_GENERATOR_MODEL' lib/roast/revision_workflow.rb` returns the 2 `ENV.fetch` calls and the comment block mentions.

#### Manual Verification:
- [x] `tmp/smoke_workflow.sh` still exits 0 (wrapper + Gemfile + frum still healthy — this workflow doesn't use the renamed envs, but it's the single guard we have that the pipeline boots).

---

## Phase 2: `ExecuteInstructionJob` + `Project` touchpoints + unit tests

### Commit
`phase 2 step 5 (2/5): ExecuteInstructionJob + workspace_initialized? + path prefix`

### Overview

Create the job with all helpers and the `run_roast_subprocess` test seam. Prefix `Project#workspace_path` so `rails new` accepts the app name. Add `Project#workspace_initialized?`. Write unit tests that stub the subprocess seam and assert every status transition + notification.

### Changes Required

#### 1. `app/models/project.rb`

**Changes**: prefix workspace path so it's a valid Rails app name; add `workspace_initialized?`.

```ruby
class Project < ApplicationRecord
  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true

  def workspace_path
    "storage/workspaces/project_#{id}"
  end

  def workspace_initialized?
    File.exist?(Rails.root.join(workspace_path, "Gemfile"))
  end
end
```

#### 2. `test/models/project_test.rb`

**Changes**: update existing `workspace_path is derived from id` assertion (line 16) to expect the new prefix. Add a test for `workspace_initialized?` — false when no Gemfile, true when Gemfile exists (use `Tempfile` or a fixture directory).

```ruby
test "workspace_path is derived from id with project_ prefix" do
  project = Project.create!(name: "X")
  assert_equal "storage/workspaces/project_#{project.id}", project.workspace_path
end

test "workspace_initialized? returns false when no Gemfile in workspace" do
  project = Project.create!(name: "X")
  assert_not project.workspace_initialized?
end

test "workspace_initialized? returns true when Gemfile exists in workspace" do
  project = Project.create!(name: "X")
  FileUtils.mkdir_p(Rails.root.join(project.workspace_path))
  File.write(Rails.root.join(project.workspace_path, "Gemfile"), "source 'https://rubygems.org'\n")
  assert project.workspace_initialized?
ensure
  FileUtils.rm_rf(Rails.root.join(project.workspace_path)) if project
end
```

#### 3. `test/controllers/projects_controller_test.rb`

**Changes**: update the assertion at line 39 to include the new prefix. The "distinct workspace_path values" test (lines 42-48) still passes as-is since prefixes + distinct IDs remain distinct.

```ruby
assert_equal "storage/workspaces/project_#{project.id}", project.workspace_path
```

#### 4. `app/jobs/execute_instruction_job.rb` (new file)

```ruby
require "shellwords"

class ExecuteInstructionJob < ApplicationJob
  queue_as :generation

  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = Rails.root.join(project.workspace_path).to_s

    prepare_workspace(workspace) unless project.workspace_initialized?
    rails_new(workspace) unless File.exist?(File.join(workspace, "Gemfile"))
    init_docs_baseline(workspace) unless File.exist?(File.join(workspace, "docs"))

    instruction.revisions.order(:position).each do |revision|
      execute_revision(revision, workspace)
      break if revision.failed?
    end

    final_phase = instruction.revisions.reload.all?(&:completed?) ? :completed : :failed
    instruction.update!(phase: final_phase)
    ActiveSupport::Notifications.instrument(
      "instruction.#{final_phase}",
      instruction_id: instruction.id
    )
  end

  private

  def prepare_workspace(workspace)
    FileUtils.mkdir_p(File.dirname(workspace))
  end

  def rails_new(workspace)
    parent = File.dirname(workspace)
    app_name = File.basename(workspace)

    Bundler.with_unbundled_env do
      ok = system(
        "cd #{Shellwords.escape(parent)} && " \
        "rails new #{Shellwords.escape(app_name)} " \
        "--css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci"
      )
      raise "rails new failed in #{parent} for #{app_name}" unless ok
    end
  end

  def init_docs_baseline(workspace)
    docs_dir = File.join(workspace, "docs")
    FileUtils.mkdir_p(docs_dir)
    {
      "architecture.md"   => "# Architecture\n\n(empty — will be filled in by the first revision)\n",
      "conventions.md"    => "# Conventions\n\n(empty — will be filled in by the first revision)\n",
      "domain.md"         => "# Domain\n\n(empty — will be filled in by the first revision)\n",
      "revision_notes.md" => "# Revision notes\n\n"
    }.each { |name, content| File.write(File.join(docs_dir, name), content) }

    system(
      "cd #{Shellwords.escape(workspace)} && git add -A && " \
      "git commit -m 'docs: scaffolding baseline' --allow-empty"
    )
  end

  def execute_revision(revision, workspace)
    revision.update!(status: :generating, started_at: Time.current)
    ActiveSupport::Notifications.instrument("revision.started", revision_id: revision.id)

    env = {
      "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
      "RAILS_APP_GENERATOR_MODEL" => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet")
    }
    args = [
      Rails.root.join("bin/roast").to_s,
      Rails.root.join("lib/roast/revision_workflow.rb").to_s,
      "--",
      "revision_id=#{revision.id}",
      "revision_summary=#{revision.summary}",
      "revision_prompt=#{revision.prompt}"
    ]

    ok, exit_code, wall_seconds = run_roast_subprocess(env, args)

    metrics = {
      wall_seconds: wall_seconds,
      exit_code: exit_code,
      git_sha: git_head(workspace)
    }

    if ok
      revision.update!(
        status: :completed,
        finished_at: Time.current,
        git_sha: metrics[:git_sha],
        metrics: metrics
      )
      ActiveSupport::Notifications.instrument(
        "revision.completed",
        revision_id: revision.id,
        git_sha: metrics[:git_sha]
      )
    else
      revision.update!(status: :failed, finished_at: Time.current, metrics: metrics)
      ActiveSupport::Notifications.instrument(
        "revision.failed",
        revision_id: revision.id,
        error: "exit #{exit_code}"
      )
    end
  end

  # Test seam — stubbed in unit tests, real in Step 7's integration test.
  def run_roast_subprocess(env, args)
    started = Time.current
    ok = system(env, *args)
    exit_code = $?.exitstatus
    wall = (Time.current - started).round(2)
    [ok, exit_code, wall]
  end

  def git_head(workspace)
    `cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null`.strip
  end
end
```

Notes:
- `queue_as :generation` — the queue pool is declared in Phase 3. Solid Queue enqueues jobs to unknown queues without error; they just wait for a matching worker.
- No `retry_on` / `discard_on` — ActiveJob default on failure is to record a `SolidQueue::FailedExecution`, retry manually.
- The `unless revision.failed?` check after `execute_revision` relies on `Revision#failed?` (AR enum predicate). If the job raises inside `execute_revision` before it can `update!(status: :failed, …)`, the revision stays in `generating` and the loop exits with the outer exception — Solid Queue records failed execution. Acceptable for PoC.

#### 5. `test/jobs/execute_instruction_job_test.rb` (new file)

Test cases (stub `run_roast_subprocess`, `prepare_workspace`, `rails_new`, `init_docs_baseline` via the same `define_singleton_method` seam pattern used in `test/tools/start_generation_test.rb:20-28`):

1. **happy path, 2 revisions both succeed** — status transitions pending → generating → completed for each; metrics populated with `wall_seconds / exit_code / git_sha`; 5 notifications emitted in order (`revision.started`, `revision.completed`, `revision.started`, `revision.completed`, `instruction.completed`); `instruction.phase == "completed"`.
2. **first revision fails** — loop breaks; second revision stays `pending`; `instruction.phase == "failed"`; notifications: `revision.started`, `revision.failed`, `instruction.failed` (no events for revision 2).
3. **second revision fails after first completes** — revision 1 `completed`, revision 2 `failed`; `instruction.phase == "failed"`; notifications include both completions.
4. **skips `prepare_workspace` + `rails_new` + `init_docs_baseline` when workspace already initialized** — stub `workspace_initialized?` → true, `File.exist?` on Gemfile/docs → true; assert those private helpers are NOT called (spy pattern).
5. **`run_roast_subprocess` seam receives correct env and args** — capture calls; assert env contains `RAILS_APP_GENERATOR_WORKSPACE` + `RAILS_APP_GENERATOR_MODEL`; args contain `bin/roast`, workflow path, `--`, `revision_id=…`, `revision_summary=…`, `revision_prompt=…`.
6. **instruction.completed/failed payload shape** — `{ instruction_id: n }`, nothing extra.
7. **revision.completed payload shape** — `{ revision_id: n, git_sha: "…" }`.
8. **revision.failed payload shape** — `{ revision_id: n, error: "exit 1" }`.

Test helper pattern (adapted from `test/tools/start_generation_test.rb:20-28`):

```ruby
def stub_run_roast_subprocess(job_class, sequence)
  calls = []
  original = job_class.instance_method(:run_roast_subprocess)
  job_class.define_method(:run_roast_subprocess) do |env, args|
    calls << { env: env, args: args }
    sequence.shift || [true, 0, 0.5]  # default success
  end
  yield calls
ensure
  job_class.define_method(:run_roast_subprocess, original) if original
end
```

Stub the three setup helpers similarly so tests don't hit the filesystem at all. Capture notification payloads via `ActiveSupport::Notifications.subscribe` with `ensure ... unsubscribe`.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test test/models/project_test.rb` green (3 new/updated tests pass).
- [x] `bin/rails test test/controllers/projects_controller_test.rb` green (updated assertion passes).
- [x] `bin/rails test test/jobs/execute_instruction_job_test.rb` green (8 tests).
- [x] `bin/rails test` fully green across the suite.
- [x] No test hits the real filesystem for workspace paths (all three setup helpers stubbed) — verify by spot-checking test output / timing.

#### Manual Verification:
- [x] The `workspace_initialized?` true-branch test manually cleans up its tempdir (confirms no leftover in `storage/workspaces/`).

**Implementation note**: test suite green but `config/queue.yml` still has the single pool — `queue_as :generation` on the job is accepted, enqueued jobs just sit there waiting for a `generation` worker (which doesn't exist yet). Phase 3 adds the pool. Pause here for manual confirmation that unit tests pass before proceeding.

---

## Phase 3: Queue pool + `instruction.requested` subscriber

### Commit
`phase 2 step 5 (3/5): generation queue + instruction.requested subscriber`

### Overview

Declare the dedicated `generation` worker pool in `config/queue.yml`, keep a separate pool for other queues. Add the only subscriber Step 5 owns: `instruction.requested` → `ExecuteInstructionJob.perform_later(id)`. Step 6 extends the initializer with `revision.*` + `instruction.{completed,failed}` subscribers.

### Changes Required

#### 1. `config/queue.yml`

**Changes**: split the worker into two pools — `generation` with strict concurrency 1, and `[default, mailers]` for everything else.

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [generation]
      threads: 1
      processes: 1
      polling_interval: 1
    - queues: [default, mailers]
      threads: 3
      processes: <%= ENV.fetch("JOB_CONCURRENCY", 1) %>
      polling_interval: 0.1

development:
  <<: *default

test:
  <<: *default

production:
  <<: *default
```

Notes:
- `processes: 1` on the `generation` pool — Solid Queue picks up jobs one at a time. Multi-instruction: the next instruction waits until the current one finishes.
- `polling_interval: 1` is fine for the generation queue (jobs are multi-minute; polling latency doesn't matter).
- The `[default, mailers]` pool preserves behavior for `ChatRespondJob` and future mailers. Dropping `"*"` means new queues need to be declared explicitly — that's a feature (prevents accidental global catch).

#### 2. `config/initializers/event_subscribers.rb` (new file)

```ruby
# Routes ActiveSupport::Notifications to downstream side-effects:
# job enqueues, Turbo broadcasts, follow-up jobs.
#
# Subscribers MUST only enqueue jobs or broadcast Turbo Streams. No business
# logic here — that lives in the tool/job handlers.
#
# Step 5 owns: instruction.requested → ExecuteInstructionJob.
# Step 6 adds: revision.* Turbo broadcasts + instruction.{completed,failed}
#            → ChatFollowUpJob.

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  ExecuteInstructionJob.perform_later(payload[:instruction_id])
end
```

#### 3. `test/jobs/execute_instruction_job_test.rb` (addition)

Add a top-level test (not in the stubbed-subprocess group) that fires the notification and asserts the job enqueues to the right queue:

```ruby
test "instruction.requested notification enqueues ExecuteInstructionJob on generation queue" do
  instruction = build_minimal_instruction  # helper: project + instruction + 1 pending revision
  assert_enqueued_with(job: ExecuteInstructionJob, args: [instruction.id], queue: "generation") do
    ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: instruction.id)
  end
end
```

The initializer loads on Rails boot, so this test exercises the real subscriber. No stub needed.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test test/jobs/execute_instruction_job_test.rb` green (all phase-2 tests + the new enqueue test).
- [x] `bin/rails test` fully green.
- [x] `bin/rails solid_queue:install` has no pending migrations (if any were introduced; should be none).

#### Manual Verification:
- [x] `bin/rails runner 'ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: 99999)'` — no raise; verified via `SolidQueue::Job` row (class_name=ExecuteInstructionJob, queue_name=generation, args=[99999]); orphan row cleaned up.
- [x] `bin/dev` starts without error (Procfile.dev's `worker: bin/jobs` picks up both pools from `config/queue.yml`).

**Implementation note**: Pause here for manual confirmation that `bin/dev` starts clean and an instrumented event shows up as a queued job before moving to Phase 4.

---

## Phase 4: `bin/execute-instruction` debug CLI

### Commit
`phase 2 step 5 (4/5): bin/execute-instruction debug CLI`

### Overview

Ship a single-purpose shell entrypoint that runs `ExecuteInstructionJob.perform_now` synchronously. Useful for:
- Step 5 DoD (Phase 5 below) — run the job without starting a worker.
- Debugging a failing instruction interactively (stdout stays in the terminal).
- Future integration tests in Step 7 (same entrypoint).

### Changes Required

#### 1. `bin/execute-instruction` (new file)

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Runs ExecuteInstructionJob synchronously in the current process.
# Useful for debugging without starting a Solid Queue worker.
#
# Usage:
#   bin/execute-instruction <instruction_id>

require_relative "../config/environment"

id = Integer(ARGV[0] || abort("Usage: bin/execute-instruction <instruction_id>"))
ExecuteInstructionJob.perform_now(id)
```

Permissions: `chmod +x bin/execute-instruction`.

### Success Criteria

#### Automated Verification:
- [x] `test -x bin/execute-instruction` (file exists and executable).
- [x] `bin/execute-instruction` without args exits non-zero with the usage message.
- [x] `bin/execute-instruction nan` exits non-zero (Integer() raises).

#### Manual Verification:
- [x] `bin/execute-instruction 999999` (non-existent ID) exits with `ActiveRecord::RecordNotFound` — proves the env boots.

---

## Phase 5: DoD manual run

### Commit
No code commit — this phase is manual verification. If it surfaces bugs, fix them in a new commit and re-run.

### Overview

The canonical Step 5 DoD from `docs/03-plans/01-phase-2-poc-generator-app.md:389`: hand-crafted `Instruction` + 1 `Revision` → `ExecuteInstructionJob.perform_now(id)` → Rails app in workspace, 2 commits, Revision `completed`, `git_sha` populated.

### Pre-flight

```
bundle outdated roast-ai
```

Expect no security fix available in `~> 1.1`. If there is, either upgrade (separate PR) or pin down and proceed.

### Manual DoD run

1. Ensure prior workspace is clean: `rm -rf storage/workspaces/project_*` (dev-only affordance).
2. Create the instruction and revision via Rails console:
   ```
   bin/rails console
   ```
   ```ruby
   project = Project.create!(name: "Welcome Probe")
   chat = project.create_chat!
   msg = chat.messages.create!(role: :user, content: "welcome controller")

   instruction = project.instructions.create!(
     anchor_message: msg,
     description: "Add a Welcome controller with index action.",
     user_intent: "welcome controller",
     phase: :implementing
   )
   instruction.revisions.create!(
     project: project,
     position: 0,
     status: :pending,
     summary: "Add Welcome controller",
     prompt: "Create a WelcomeController with an index action rendering a Tailwind-styled landing page. Add a root route. Add a system test covering root."
   )

   puts "Instruction ID: #{instruction.id}"
   ```
3. Exit console. Run synchronously:
   ```
   bin/execute-instruction <instruction_id>
   ```
4. Wait for completion (~2-5 min).

### Success Criteria (DoD)

#### Automated Verification:
- [ ] `cd storage/workspaces/project_<project_id> && git log --oneline | wc -l` ≥ 2 (scaffolding baseline + revision commit).
- [ ] `bin/rails runner "r = Revision.find(<revision_id>); raise unless r.completed? && r.git_sha.present? && r.metrics['exit_code'] == 0"` — no raise.
- [ ] `bin/rails runner "raise unless Instruction.find(<instruction_id>).completed?"` — no raise.
- [ ] Workspace's own test suite green: `cd storage/workspaces/project_<id> && bin/rails test` (subset of W2.4 verify already ran inside the workflow; repeating outside confirms the app is healthy).

#### Manual Verification:
- [ ] `cd storage/workspaces/project_<id> && bin/rails server` — root URL renders the Tailwind-styled landing page.
- [ ] No leftover processes (`ps aux | grep roast` — should be empty after the CLI returns).

---

## Testing Strategy

### Unit tests (Phase 2 + 3)

Stub the three setup helpers (`prepare_workspace`, `rails_new`, `init_docs_baseline`) and the `run_roast_subprocess` seam. No real filesystem, no real subprocess. Coverage:

- Revision status transitions (pending → generating → completed|failed).
- Instruction phase transition (implementing → completed|failed).
- `break if revision.failed?` loop exit.
- Notification payload shape for all 5 events.
- Env hash + args array passed to the seam.
- Skips of setup helpers when workspace already initialized.
- `instruction.requested` notification → job enqueue on `generation` queue.

### Integration test (Step 7 scope, not Step 5)

Real subprocess. Step 5's `run_roast_subprocess` seam is private but callable via the default path — Step 7's test just doesn't stub it. Budget 15 min wall.

### Manual DoD (Phase 5)

Real rails_new, real bin/roast, real Claude CLI. Single revision to keep wall time ~2-5 min for faster iteration than the full 3-revision TODO fixture from the spike.

## Performance Considerations

- **Wall time per revision** — spike measured 70-226s. Acceptable for PoC.
- **`rails new` cost** — one-time per project. Includes `bundle install` which is the heaviest step. Shared bundle cache (`~/.bundle`) inherits from the host shell; if cold, adds ~60s. Out of scope for Step 5; revisit in Step 7 if E2E budget is tight.
- **Queue isolation** — dedicated `generation` worker with `threads: 1, processes: 1` means one active generation per deployment. Other queues (chat, mailers) unaffected. Matches the "one active instruction per project" constraint from `docs/01-vision/02-user-journey.md` § Parallel instructions.
- **No hard timeout** — intentional for PoC. If a revision hangs, kill the worker process manually (`ps aux | grep bin/jobs` → kill).

## Migration Notes

No DB migrations. Existing projects (if any) remain untouched; `workspace_path` format changes from `storage/workspaces/<id>` to `storage/workspaces/project_<id>` at the method level only — no data to update. Any pre-existing workspace directories under the old path become orphans; clean up manually (`rm -rf storage/workspaces/<id>` for each non-prefixed name).

## ENV hygiene summary

| ENV var | Who sets it | Who reads it | Notes |
|---|---|---|---|
| `RAILS_APP_GENERATOR_WORKSPACE` | `ExecuteInstructionJob#execute_revision` | `lib/roast/revision_workflow.rb:21-23` | absolute path, derived from `Rails.root.join(project.workspace_path)` |
| `RAILS_APP_GENERATOR_MODEL` | `ExecuteInstructionJob#execute_revision` (defaults "sonnet") | `lib/roast/revision_workflow.rb:24` | passed to Roast's `agent` step; resolved by Claude CLI (subscription OAuth via `bin/roast`) |
| `ANTHROPIC_*` | user's shell (possibly) | — | unset by `bin/roast` wrapper (lines 9-14) |
| `BUNDLE_*` / `BUNDLER_*` / `RUBYOPT` | generator's `bundle exec` parent | `VerifyRevision.with_clean_bundler_env` unsets before workspace shell | third ENV leak from Phase 1 findings; already solved |
| `OPENROUTER_API_KEY` | — | `bin/roast-openrouter:7` | Step 5 doesn't use this; Haiku via OpenRouter is a future swap (change `bin/roast` → `bin/roast-openrouter` in the args array) |

## References

- Research: `thoughts/shared/research/2026-04-20/phase-2-step-5-execute-instruction-job.md`
- Spike driver (1:1 source): `spikes/roast/new_app_driver.rb:62-148`
- Spike findings (3 ENV gotchas): `spikes/roast/findings.md:152-159`
- Phase 2 plan pseudocode: `docs/03-plans/01-phase-2-poc-generator-app.md:310-389`
- Phase 2 architecture: `docs/02-architecture/01-workflows-and-decisions.md:125-135` (W2.3 prompt invariants), `docs/02-architecture/02-layer-integration.md:37-52` (event names/payloads)
- Roast wrapper: `bin/roast:9-25`
- Revision workflow: `lib/roast/revision_workflow.rb:21-206`
- Verify helper: `lib/roast/verify_revision.rb:58-65`
- Notification emit site (Step 4): `app/tools/start_generation.rb:48-51`
- Test patterns to reuse: `test/tools/start_generation_test.rb:20-28, 62-77`; `test/jobs/chat_respond_job_test.rb:125-146`
- Current queue config: `config/queue.yml:1-19`
- Current `Project#workspace_path`: `app/models/project.rb:8-10`
