# Phase 5 Step 2 — Eliminate post-failure waste in revision workflow

## Overview

A production run (`tmp/simple_application_run_kamal.log`) burned **$4.36 across 3 revisions and shipped 0 commits** — every revision aborted in `ensure_passing`, the workspace was reset, but the workflow kept running, paying for downstream `update_docs` agent calls that documented code that no longer existed. The two recent commits (`dc41814`, `13f22a8`) addressed the env-fight problems and added `AutoRemediate` for known-recipe verify failures, but three concrete waste patterns remain. This plan eliminates them.

## Current State Analysis

**The log shows three independent waste patterns that the recent commits don't cover:**

1. **`update_docs` runs after `ensure_passing` fails** (lines 521–1295 of the log, then again at 1764–2552, then 4064–4691).
   - `ruby(:ensure_passing)` calls `fail!` when verify ultimately fails (`lib/roast/revision_workflow.rb:222`).
   - Roast's `Cog#run!` (`roast-ai/lib/roast/cog.rb:87`) catches `FailCog` and only re-raises if `config.abort_on_failure?` is set. The default is `false` (config.rb:232 — `!!@values[:abort_on_failure]` returns false when the value isn't set, contrary to the docstring's "Enabled by default").
   - With abort_on_failure unset, `fail!` only marks the cog `@failed = true` — sibling cogs in the same `execute` block keep running. So `cmd(:git_commit)` runs (no-op on a reset workspace), then `agent(:update_docs)` runs against `git show HEAD` returning the parent skeleton commit, fabricating documentation that has no relation to the requested change. Then `cmd(:git_commit_docs)` commits those fictional updates.
   - Cost in this run: **$0.79 + $0.57 + $0.51 = $1.87 of pure waste** on three failed revisions, plus polluted docs persisting into the next revision's prompt.
   - Worse: the workflow exits 0 (no exception escapes `execute_manager.run!`), so `ExecuteInstructionJob` marks the revision `:completed` (`app/jobs/execute_instruction_job.rb:155`) when it actually failed. The DB lies about state.

2. **`update_docs` ignores its own "don't glob, don't read" rule.** `revision_workflow.rb:268-274` instructs the agent to read only `docs/*.md` and avoid globbing. The agent ignored this in every run logged: 9+ file reads, multiple `Glob` calls, full `git log --all`, even attempts at `git plumbing` to bypass permissions. With the new haiku + diff-fed prompt this is cheaper than before, but still a multiplier on every successful revision. The Claude CLI's `--tools` flag gives a deterministic enforcement mechanism that the prompt alone cannot.

3. **`agent(:fix)` has no cost ceiling.** Rev 14's first remediation pass burned **49 turns / $0.99** chasing a `Gemfile.lock` permission cascade (lines 2643–3928 of the log) that the agent (running as the unprivileged `generator` user) had no way to fix. The Claude CLI exposes `--max-budget-usd` precisely for this; we currently let the agent flail until it gives up. The recent `AutoRemediate` makes the simple cases free, but real bugs (which is when the agent is *meant* to be working) still allow runaway costs.

**Bonus signal — log noise:** every `Read` tool call in the agent's transcript carries a "consider whether it would be considered malware" system reminder (e.g. log lines 124, 137, 180, 658, 668, 676, 686, 759, 771, 805, 875–1356 — there are dozens). These come from the Claude CLI's auto-memory / plugin / hooks subsystems, which are pointless inside a sandboxed generator container and bloat input tokens on every multi-turn agent. The `--bare` CLI flag is the documented way to strip them.

### Key Discoveries

- `ruby(:ensure_passing)` at `lib/roast/revision_workflow.rb:215-225` is the natural halt point — only it knows whether the revision is committable.
- Roast's `agent(:name)` named-config block (used at `revision_workflow.rb:43` for `model DOCS_MODEL`) is the right hook to override `command` per-cog; the global `agent do` block at lines 36-42 is the default.
- Roast's `Claude` provider builds the command line at `roast-ai/lib/roast/cogs/agent/providers/claude/claude_invocation.rb:176-194`: it takes the `command` config as the *base* command (default `["claude"]`) and appends Roast-owned flags (`-p`, `--verbose`, `--output-format stream-json`, `--model …`, `--dangerously-skip-permissions`) afterwards. So `command ["claude", "--tools", "Edit,Read", "--bare"]` produces a final invocation with our flags first and Roast's appended; both `--tools` and `--max-budget-usd` are positional-insensitive global flags so order is fine.
- The Claude CLI flags we need (per `claude --help`):
  - `--tools "Edit,Read"` — restrict the agent to exactly those tools (no Bash, no Glob, no Write, no TodoWrite).
  - `--max-budget-usd 0.50` — hard kill the agent process when total spend hits the cap (only works with `--print`, which Roast already passes).
  - `--bare` — skip auto-memory, hooks, plugin sync, CLAUDE.md auto-discovery. Compatible with `--allowedTools`/`--tools` and `--max-budget-usd`.
- `AutoRemediate` already runs from the workflow process (root context inside the container), so it can write to root-owned `Gemfile.lock` even when the `generator`-user agent can't. This means a post-reset chmod or a `Gemfile.lock` recipe is **not** needed — AutoRemediate masks the issue. The 49-turn flail in the log is from a code state that pre-dates `AutoRemediate`; it won't reproduce now.
- The Roast workflow's exit code is determined by whether an exception escapes `Workflow#start!` (`roast-ai/lib/roast/workflow.rb:60-73`). Only `ControlFlow::Break` is caught at that level; `FailCog` re-raises when `abort_on_failure?` is true and propagates out → process exits non-zero → `ExecuteInstructionJob#run_roast_subprocess` returns `ok=false` → revision is correctly marked `:failed`.

## Desired End State

When a revision's verify cannot be made to pass (after auto-remediation and up to 2 LLM fix iterations):
- The Roast workflow halts at `ensure_passing` with a non-zero exit code.
- No `cmd(:git_commit)`, `agent(:update_docs)`, `cmd(:git_commit_docs)`, or `ruby(:report)` runs. Zero LLM tokens spent on a failed revision past the fix loop.
- `ExecuteInstructionJob` correctly marks the revision `:failed` (already wired up; just needs the non-zero exit).

When a revision succeeds:
- `agent(:update_docs)` runs the Claude CLI with **only Edit + Read tools** and `--bare`, so it cannot glob the workspace, run Bash, or pull in auto-memory/plugin context. Worst case it edits docs files; nothing else.

When `agent(:fix)` runs:
- The Claude CLI is invoked with `--max-budget-usd 0.50` and `--bare`. A flail caps at $0.50 instead of $1.00+. Auto-memory / plugin context that bloats input tokens is stripped.

### Verification

- A forced-failing-verify run (e.g. running the workflow against a workspace whose `bin/rails` is broken) exits non-zero, the workflow log ends at `[W2.F2] Resetting uncommitted changes in workspace`, and there is no `agent(:update_docs)` log line.
- A successful run's `update_docs` log shows only `Edit` and `Read` tool calls — no `Bash`, `Glob`, `TodoWrite`, or `Write`.
- A simulated 49-turn flail (e.g. the Gemfile.lock-perm scenario, reproducible by chmoding Gemfile.lock 644 root-owned in a test workspace) terminates at ~$0.50 instead of $0.99+.

## What We're NOT Doing

- **Not changing planner granularity.** The 3-revisions-for-1-feature problem (rev 12 controller, rev 13 route, rev 14 view, all rebuilding the same homepage) is real, but it's a `CreatePlan` issue, not a Roast issue. Separate plan.
- **Not adding a `Gemfile.lock` permission recipe to AutoRemediate.** AutoRemediate runs from root context and writes Gemfile.lock fine; the recipe isn't needed. (The log's 49-turn flail predates AutoRemediate.)
- **Not adding `--bare` to `agent(:generate_code)`.** `generate_code` benefits from full agent context for reasoning. Restricted to `update_docs` and `fix` where the work is mechanical.
- **Not investigating why `bundle install` is needed every revision** (a structural question about gem persistence between revisions). It's wall-time waste, not token waste, and AutoRemediate makes it cheap.
- **Not adding new automated tests for Roast DSL config introspection.** Roast doesn't expose a clean API for reading config back; manual verification + the existing E2E_GENERATE integration test are the right gates here.

## Implementation Approach

Three small phases, each one atomic config change in `lib/roast/revision_workflow.rb`. No new files, no refactors. Each phase is independently testable and shippable.

The whole change is roughly 6 lines of code in one file. The plan length is mostly verification scaffolding.

---

## Phase 1: Halt the workflow when ensure_passing aborts

### Commit
`phase 5 step 2: halt revision workflow on verify failure`

### Overview
Add `abort_on_failure!` to the `ensure_passing` cog so that its `fail!` propagates out of the workflow. Downstream cogs (`git_commit`, `update_docs`, `git_commit_docs`, `report`) won't run. Process exits non-zero → `ExecuteInstructionJob` marks the revision `:failed` correctly.

### Changes Required

#### 1. Configure `ensure_passing` to abort on failure
**File**: `lib/roast/revision_workflow.rb`
**Changes**: Add a named-cog config in the `config do` block. Place it next to the existing `agent(:update_docs)` config so all per-cog overrides are colocated.

```ruby
config do
  agent do
    provider :claude
    model CLAUDE_MODEL
    working_directory WORKSPACE
    skip_permissions!
    show_stats!
  end
  agent(:update_docs) { model DOCS_MODEL }
  cmd { display! }

  # When verify ultimately fails, ensure_passing's fail! must halt the
  # workflow — without this, downstream cogs (git_commit, update_docs,
  # git_commit_docs, report) keep running on a reset workspace, fabricating
  # documentation against the parent commit and burning ~$0.5/failed
  # revision. abort_on_failure! re-raises FailCog out of the cog, past the
  # workflow runner, producing a non-zero exit so ExecuteInstructionJob
  # marks the revision :failed instead of :completed.
  ruby(:ensure_passing) { abort_on_failure! }
end
```

The body of `ruby(:ensure_passing)` does not change — the `puts [W2.F1]/[W2.F2]` and `git reset --hard` still run, then `fail!` propagates instead of being swallowed.

### Success Criteria

#### Automated Verification:
- [ ] Existing test suite passes: `bin/rails test`
- [ ] Existing AutoRemediate tests still pass: `bin/rails test test/lib/auto_remediate_test.rb`
- [ ] Existing VerifyRevision tests still pass: `bin/rails test test/lib/verify_revision_test.rb`
- [ ] Existing ExecuteInstructionJob tests still pass: `bin/rails test test/jobs/execute_instruction_job_test.rb`
- [ ] Smoke workflow still parses: `bin/roast-claudesubscription lib/roast/smoke_workflow.rb` exits 0 (proves the DSL config still loads cleanly with the new line)

#### Manual Verification:
- [ ] In a scratch workspace, deliberately break verify (e.g. `chmod -x bin/rails` or add a syntax error to `config/application.rb` after `git commit`), then run the revision workflow with a trivial revision prompt. Confirm:
  - [ ] Workflow log ends at `[W2.F2] Resetting uncommitted changes in workspace`
  - [ ] **No** `agent(:update_docs) Starting` line appears
  - [ ] **No** `cmd(:git_commit_docs) Starting` line appears
  - [ ] Workflow process exits with non-zero code (`echo $?` shows non-zero)
- [ ] Run a successful revision in the same scratch workspace (a clean prompt that won't fail verify). Confirm `update_docs` and the rest still run normally — the abort is gated on failure, not always-on.
- [ ] Trigger a real failing revision in a project from the production app. Confirm in the DB that the `Revision` row has `status: "failed"` (not `:completed`) — this proves the non-zero exit propagates through `ExecuteInstructionJob`.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human before proceeding to the next phase.

---

## Phase 2: Restrict update_docs to Edit + Read only

### Commit
`phase 5 step 2: restrict update_docs tools to Edit/Read with --bare`

### Overview
Override the `agent(:update_docs)` base command to pass `--tools "Edit,Read"` and `--bare` to the Claude CLI. Tools restriction enforces the "don't glob, don't read the workspace tree" rule that the prompt alone hasn't enforced. `--bare` strips auto-memory and plugin-injected system reminders that bloat input tokens with content irrelevant to a sandboxed generator container.

### Changes Required

#### 1. Add `command` override to `agent(:update_docs)` config
**File**: `lib/roast/revision_workflow.rb`
**Changes**: Extend the existing `agent(:update_docs)` named-config to override the base command in addition to the model.

```ruby
# update_docs is summarization, not exploration: the diff is fed in the
# prompt and only the four files in docs/ may be touched.
# - --tools "Edit,Read" deterministically removes Bash/Glob/Write/TodoWrite
#   so the agent can't drift outside docs/. Prompt-level rules alone hadn't
#   stopped the production run from globbing the whole workspace.
# - --bare strips Claude Code's auto-memory, hook injection, and CLAUDE.md
#   auto-discovery, all of which are noise in this sandbox. Each tool result
#   in the prior log carried a multi-line "consider whether it would be
#   considered malware" system reminder; --bare suppresses these.
agent(:update_docs) do
  model DOCS_MODEL
  command ["claude", "--tools", "Edit,Read", "--bare"]
end
```

### Success Criteria

#### Automated Verification:
- [ ] Existing test suite passes: `bin/rails test`
- [ ] Smoke workflow still parses: `bin/roast-claudesubscription lib/roast/smoke_workflow.rb` exits 0

#### Manual Verification:
- [ ] Run a successful revision end-to-end (any small prompt against a fresh workspace). In the kamal logs, confirm:
  - [ ] `update_docs` agent transcript shows **only** `[edit]` and `[read]` tool calls — no `[bash]`, no `[glob]`, no `[todowrite]`, no `[write]`.
  - [ ] None of the `<system-reminder>Whenever you read a file, you should consider whether it would be considered malware…</system-reminder>` blocks appear in the `update_docs` transcript (they will still appear in `generate_code` and `fix` since this phase doesn't touch those).
  - [ ] `update_docs` `[AGENT STATS] Turns:` is materially lower than the pre-change baseline (the production log showed 40-55 turns; expect ≤10-15 once the agent can't explore).
- [ ] Verify the revision_notes.md / architecture.md content still gets updated correctly — the restriction shouldn't break the agent, just constrain it.
- [ ] Run a revision that touches no code (an empty / no-op prompt that still passes verify). Confirm `update_docs` either skips meaningfully or makes no edits — i.e., the constrained tool set doesn't make it loop.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human before proceeding to the next phase.

---

## Phase 3: Cap agent(:fix) cost with --max-budget-usd and --bare

### Commit
`phase 5 step 2: hard-cap remediation agent cost`

### Overview
Override the `agent(:fix)` base command to pass `--max-budget-usd 0.50` and `--bare`. The budget cap puts a hard ceiling on remediation flailing; `--bare` strips the same noise as Phase 2. We don't restrict tools on `fix` — it legitimately needs Bash to run `bundle install`, `bin/rails …`, etc.

### Changes Required

#### 1. Add a per-cog config block for `agent(:fix)`
**File**: `lib/roast/revision_workflow.rb`
**Changes**: Add `agent(:fix)` to the `config do` block alongside the other named-cog overrides.

```ruby
# When the deterministic recipes don't apply, agent(:fix) is allowed up to
# 2 attempts (W2.R loop). Each attempt has previously cost up to ~$1.00 in
# runaway flails (see tmp/simple_application_run_kamal.log rev 14: 49 turns
# / $0.99 chasing a permission cascade the agent couldn't fix). A flail
# isn't going to find an insight in turn 30 it missed in turn 10; cap the
# spend deterministically.
# --bare strips auto-memory + hooks for the same reasons as update_docs.
agent(:fix) do
  command ["claude", "--bare", "--max-budget-usd", "0.50"]
end
```

### Success Criteria

#### Automated Verification:
- [ ] Existing test suite passes: `bin/rails test`
- [ ] Smoke workflow still parses: `bin/roast-claudesubscription lib/roast/smoke_workflow.rb` exits 0

#### Manual Verification:
- [ ] Run a revision that triggers a real (non-AutoRemediate-able) verify failure to drive the agent into the fix loop. Confirm in the kamal log:
  - [ ] `agent(:fix)` `[AGENT STATS] Cost (USD)` is bounded at ~$0.50 or less (the cap is per-process; if the agent legitimately fixes things in less, that's fine — we're testing the upper bound).
  - [ ] If the agent hits the cap, it terminates cleanly (claude CLI exits, Roast records the cog as failed) and the W2.R loop either retries (iter 1) or falls through to ensure_passing (which now halts cleanly per Phase 1).
- [ ] Verify a successful single-iteration fix (e.g. the AutoRemediate-handled bundle case where the agent isn't even reached) still works — Phase 3 shouldn't change behavior when fix is short-circuited.
- [ ] Run a known-good revision that doesn't enter the fix loop at all. Confirm Phase 3 has zero side effects there.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human.

---

## Testing Strategy

### Unit Tests
No new unit tests. The change is three lines in three Roast `config do` blocks. Roast's DSL doesn't expose a clean introspection API for reading config back, so unit-testing "the config has these flags" would either reach into Roast internals (fragile) or duplicate the source as a string-match assertion (cargo). The existing `auto_remediate_test.rb` and `verify_revision_test.rb` continue to cover the deterministic logic that surrounds the workflow.

### Integration Tests
The existing `test/integration/generate_todo_list_test.rb` (gated on `E2E_GENERATE=1`) exercises the full `POST /projects` → `ChatRespondJob` → `StartGeneration` → `ExecuteInstructionJob` chain through the real `bin/roast` subprocess. It already asserts on revisions completing and code being committed. After this plan ships, it should still pass — the restrictions don't change the success path. **It's the regression gate**: if it goes red, something's wrong.

We don't add an `E2E_FAIL=1` variant for forced-failing revisions in this plan — the manual verification steps cover the failure path, and an automated forced-fail E2E would need either a stubbed agent or a deterministic-failing fixture, both of which add infrastructure disproportionate to this plan's scope.

### Manual Testing
Per-phase manual verification is documented above. The end-to-end story is:
1. Spin up a scratch project in dev (`bin/dev`, `POST /projects` with a small prompt).
2. Add a few revisions that succeed normally — confirm Phase 2 restrictions don't break the success path.
3. Force a failure (e.g. a malformed prompt that produces uncompilable code, or `chmod -x bin/rails` mid-flow) — confirm Phase 1 halts cleanly.
4. Watch the kamal log for `update_docs` and `agent(:fix)` transcripts — confirm Phase 2's tool restrictions and Phase 3's cost cap are visible.

## Performance / Cost Considerations

Estimated per-revision savings (relative to the production log baseline):

| Path | Baseline cost | After this plan | Savings |
|---|---|---|---|
| Failed revision (verify never passes) | $0.5–$0.8 (`update_docs` runs on phantom diff) | $0 (workflow halts at `ensure_passing`) | **$0.5–$0.8 / failed revision** |
| Successful revision (`update_docs`) | $0.10–$0.15 with current haiku + diff prompt, but agent still globs/explores | Lower bounded by tool restrictions; expect ≤$0.05 (1-3 Read + 1-4 Edit) | **~50%** |
| Worst-case fix loop (real bug, agent flails) | up to $1.00 / iteration × 2 iterations = $2.00 | $0.50 / iteration × 2 = $1.00 | **up to $1.00 / failed-fix revision** |
| `--bare` input-token bloat (every multi-turn agent call) | ~10-30% of input tokens go to auto-memory + reminders | 0 | small but compounds across all turns |

Aggregate, on a 3-revision run that hits the production-log failure pattern: **$4.36 → ~$2.00**.

## References

- Production-run log analyzed: `tmp/simple_application_run_kamal.log`
- Recent commits this builds on:
  - `dc41814` — workspace permissions, BUNDLE_FROZEN, RAILS_ENV=development
  - `13f22a8` — VerifyRevision short-circuit, AutoRemediate, update_docs on haiku + diff prompt
- Roast internals referenced:
  - `roast-ai-1.1.0/lib/roast/cog.rb:87` — `FailCog` re-raises only when `abort_on_failure?`
  - `roast-ai-1.1.0/lib/roast/cog/config.rb:201-233` — `abort_on_failure!` / `abort_on_failure?`
  - `roast-ai-1.1.0/lib/roast/cogs/agent/providers/claude/claude_invocation.rb:176-194` — Claude CLI command construction
  - `roast-ai-1.1.0/lib/roast/workflow.rb:60-73` — only `ControlFlow::Break` is caught at the workflow boundary; everything else propagates → non-zero exit
- Claude CLI flags: `claude --help` (`--tools`, `--max-budget-usd`, `--bare`, `--allowedTools`, `--disallowedTools`)
- Existing tests as patterns: `test/lib/auto_remediate_test.rb`, `test/lib/verify_revision_test.rb`
- Workflow definition: `lib/roast/revision_workflow.rb`
- Job entry point: `app/jobs/execute_instruction_job.rb:118-173` (revision execution + DB state)
