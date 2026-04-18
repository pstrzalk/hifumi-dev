# Roast Spike — Findings

Validation of Roast 1.1.0 (Shopify) against the architecture in `../../docs/02-architecture/01-workflows-and-decisions.md`.

## Verdict: it works. Architecture on target, API surface needs corrections.

All key elements tested and working:
- `cmd()`, `ruby()`, `agent()` — generate → verify → commit pipeline
- `repeat()` + `fail!` + `break!` — remediation loop
- `working_directory` + `skip_permissions!` — Claude CLI writes to the specified directory
- `kwarg()` — parameters from the CLI
- Data passing via bang suffix (`cmd!(:name)`, `ruby!(:name).value`)

---

## Tested (with results)

### test_basic.rb — cmd + ruby + data passing
```
cmd(:hello) → ruby(:process) → cmd(:result)
Result: "Processed: HELLO FROM ROAST (16 chars)"
```

### test_remediation.rb — remediation loop pattern
```
generate → initial_verify(FAIL) → repeat(:remediate):
  iteration 0: fix → verify(FAIL) → continue
  iteration 1: fix → verify(FAIL) → continue
  iteration 2: fix → verify(PASS) → break!
Result: "remediation succeeded"
```

### test_agent.rb — full pipeline with Claude CLI
```
cmd(:setup) git init → agent(:generate) Claude CLI → cmd(:verify) minitest → cmd(:commit) git
Agent stats: 3 turns, 7 seconds, $0.015 (Haiku)
Verify: 3 runs, 9 assertions, 0 failures, 0 errors
Commit: c63ae93 — 2 files
```

---

## What needs fixing in our docs

### 1. Workflow = a .rb file, not a Ruby class

**Docs say:**
```ruby
class RevisionWorkflow < Roast::Workflow
  execute do ...
```

**Roast actually:**
```ruby
# revision_workflow.rb (plain file)
config do ...
execute do ...
```

**Impact on architecture:** Integration with our Rails app is via `system("roast", "execute", "workflow.rb", ...)` from a Solid Queue job. Not `RevisionWorkflow.new.call`. Less Ruby-native, but we get session replay and tracing for free.

### 2. Error handling: `fail!` + `repeat()`, not `rescue_from`

**Docs say:**
```ruby
rescue_from VerificationFailed do |errors|
  retry_count = 0
  loop do ...
```

**Roast actually:** `rescue_from` doesn't exist. `fail!` marks a cog as failed but the workflow continues. Remediation loop via:
- `ruby(:verify)` with `fail!` when a check doesn't pass
- `ruby?(:verify)` returns false for a failed cog
- `repeat(run: :fix_scope)` with `break!` inside

Tested — works well. The pattern is even clearer than rescue.

### 3. Parameters: `kwarg(:key)`, not constructor args

CLI: `roast workflow.rb -- revision_id=123 workspace=/tmp/app`
Workflow: `kwarg(:revision_id)`, `kwarg(:workspace)`

Format: `key=value`, not `--key value`.

### 4. `repeat` has no `max_iterations` — control via `break!`

```ruby
execute(:fix_scope) do
  agent(:fix) { |_, errors| "Fix: #{errors}" }
  ruby(:verify) { fail! if checks_fail }
  ruby { |_, _, idx| break! if ruby?(:verify) || idx >= 2 }
  outputs { ruby?(:verify) ? "ok" : "errors: ..." }
end
```

### 5. Agent requires `skip_permissions!` and `working_directory`

Without `skip_permissions!` Claude CLI asks for permission to write (and doesn't get an answer in batch mode → timeout/fail).

```ruby
config do
  agent do
    provider :claude
    model "sonnet"
    working_directory "/path/to/workspace"
    skip_permissions!
  end
end
```

**Security note:** `skip_permissions!` = `--dangerously-skip-permissions` in Claude CLI. Acceptable because the workspace is isolated per project. But confirms that preview isolation (containers) is required in production.

---

## Costs (measured)

| Operation | Model | Time | Cost |
|---|---|---|---|
| agent(:generate) — 2 Ruby files | Haiku | 7s | $0.015 |

For a full Rails app generation (6 revisions × Sonnet) estimate: 6 × ~$0.10-0.30 = **$0.60-1.80 per instruction**. Plus planning, research, doc updates. Realistically **$1-3 per generation** with Sonnet. With remediation loop: up to $5.

---

## Spike files

- `test_basic.rb` — cmd + ruby + data passing (10s test)
- `test_remediation.rb` — repeat + fail! + break! pattern
- `test_agent.rb` — full agent → verify → commit pipeline (proven pattern)
- `revision_workflow.rb` — W2 (proven, run on the todo-list plan)
- `new_app_driver.rb` — Ruby wrapper corresponding to the future Solid Queue job: rails new + loop shelling `bin/roast revision_workflow.rb`
- `new_app_workflow.rb` — W1 draft (unused — the driver replaced it)
- `verify_revision.rb` + `bin/verify` — deterministic verify helper
- `plans.rb` — `todo-list` (3 revisions happy path) and `force-remediation` (1 revision with forced failure)
- `bin/roast` — wrapper for Claude Code subscription (unset API env + pin Ruby from .ruby-version)
- `bin/roast-openrouter` — paid fallback via OpenRouter

---

## Full pipeline tested end-to-end (2026-04-15)

Plan `todo-list` (3 revisions × Sonnet) run via `new_app_driver.rb` under the Claude Code subscription. Result: **3/3 completed, 496s wall, zero remediation**. Evidence: `tmp/metrics_todo-list_1776288069.json`, git log in `tmp/todo-spike/`.

| Revision | Wall | SHA |
|---|---|---|
| Todo model + validations + tests | 128s | 404e402 |
| TodosController (REST) + tests | 142s | ef00bc3 |
| Tailwind + Hotwire Turbo views | 226s | dc141e3 |

Each revision was verified by the sequence: `bundle check` → `db:prepare` → `herb lint` (skipped because gem not installed) → `boot check` → `rails test`. All PASS.

### Three ENV gotchas that had to be fixed to pass the pipeline

All silent killers, each blocked the whole run. Fixes in commit b94e9a7. Details in memory `feedback_roast_rails_env_gotchas.md`:

1. **`ANTHROPIC_API_KEY` leaks into Claude CLI** (driver via `bundle exec roast` instead of `bin/roast`) → Claude hits the API, gets 429. Fix: the driver MUST call `bin/roast`.
2. **frum shim resolves the wrong Ruby version** when `bundle` is spawned as a subprocess under a different Ruby than `.ruby-version`. `GemNotFound` for Roast gems. Fix: `bin/roast` pins PATH to `$HOME/.frum/versions/$(cat .ruby-version)/bin`.
3. **`BUNDLE_GEMFILE` leaks from `bundle exec roast` into `bin/rails` in the workspace** — the workspace loads the spike's gems, `bootsnap/setup` LoadError. Fix: `VerifyRevision.with_clean_bundler_env` unsets `BUNDLE*`/`BUNDLER*`/`RUBYOPT` before shelling to the workspace.

---

## Costs (measured)

| Operation | Model | Time | Cost |
|---|---|---|---|
| agent(:generate) — 2 Ruby files | Haiku | 7s | $0.015 |
| Full W1 todo-list (3 revisions) | Sonnet via subscription | 496s wall | $0 actual (covered by subscription) |

**Note:** Claude CLI in the Roast log reports an "informational" price (e.g. $0.13 per revision 1, ~$1.5 total for todo-list) — that's API pricing, not actual subscription usage. If a hard number is needed for the DoD, the same pipeline has to be run through `bin/roast-openrouter` one-off (deferred, optional — see Next steps #4).

---

## Lessons for docs

1. **`../../docs/02-architecture/01-workflows-and-decisions.md`:** Fix the Roast example — files instead of classes, `fail!`/`break!` instead of `rescue_from`
2. **`skip_permissions!` as a requirement** for agent config
3. **Ruby 3.3+ requirement** (Roast 1.x). Add to `../../docs/02-architecture/03-tech-stack.md`.
4. **Session replay:** free with Roast, can resume workflow from a step — good for debugging and `--replay` after rate limit.
5. **ENV hygiene in driver/wrapper:** three leaks (point above) are systemic enough to describe in architecture as a requirement, not just a workaround.

## Step 4 closed — remediation loop validated (2026-04-16)

Plan `force-remediation` (1 revision × Sonnet) — prompt with an explicit contradiction: validation `price_cents >= 100` + a test expecting valid for `price_cents: 50`. Result: **all_succeeded, 131s wall, 1 remediation iteration**. Evidence: `tmp/metrics_force-remediation_1776291035.json`, `tmp/remediation-spike/`.

Full workflow path:
1. `generate_code` → Claude wrote literally what we asked (validation + test with the contradiction)
2. `verify` (W2.4) → `bundle` / `db:prepare` / `boot` PASS, `rails test` **FAIL** with assertion "Price cents must be greater than or equal to 100"
3. `repeat(:remediate)` → `fix_and_reverify[0]` → `agent(:fix)` diagnosed and chose: remove `greater_than_or_equal_to: 100`, keep the test
4. `reverify` → PASS → `break!` after the first attempt
5. W2.5 commit code → W2.6 update docs → W2.7 commit docs → W2.8 report

### Bug caught: `metadata` does not exist in Roast DSL blocks

The first attempt blew up with `NameError: undefined local variable or method 'metadata' for Roast::CogInputContext`. In `test_agent.rb` and the todo-list happy path the bug didn't fire because `verify` always passed on the first try and the `metadata[:verify_errors] = errors` line never executed.

**Fix:** module-level hash `WORKFLOW_STATE = {}` defined at the top of `revision_workflow.rb`, used to pass errors from `ruby(:verify)` to the `repeat(:remediate)` block. Commit `fc5f4cd`.

**Implication for docs:** the W2 example in `../../docs/02-architecture/01-workflows-and-decisions.md` used `ruby(:verify).error` — that also didn't work in practice (a cog after `fail!` doesn't expose `.error`). Updated to the `WORKFLOW_STATE` pattern.

---

## Verdict: WE GO to Phase 2 (PoC of the main generator app)

W1 → W2 + remediation architecture validated end-to-end on a real Rails app. Happy path and failure path both closed. The stack Roast 1.1 + Claude Code CLI + Ruby wrapper (equivalent of a Solid Queue job) works.

Known limitations and gotchas documented:
- `metadata` unavailable in DSL blocks — workaround: module-level hash
- Three ENV leaks (`ANTHROPIC_API_KEY` / frum Ruby shim / `BUNDLE_GEMFILE`) — workaround: `bin/roast` wrapper + `VerifyRevision.with_clean_bundler_env`
- `skip_permissions!` requires an isolated workspace (→ Phase X: preview isolation with Kamal+Docker)

## Next steps (what was left from the Phase 1 plan)

1. ✅ ~~Rewrite revision_workflow.rb following test_agent.rb~~
2. ✅ ~~Test happy path on a real Rails app (todo-list plan, 3 revisions)~~
3. ✅ ~~Run the `force-remediation` plan — remediation loop validated~~
4. ⬜ (Optional, deferred) real cost via OpenRouter — the subscription doesn't expose tokens; to be measured when Phase 2 DoD requires it
5. ✅ ~~Update documents (`findings.md`, `../../docs/02-architecture/01-workflows-and-decisions.md` — commit ff73377; `index.md` was later removed during documentation reorganization)~~
6. ✅ ~~Cleanup: `tor-1-plan.md` removed (commit ff73377), `project_tor_1_*` memories never existed on this host~~

**Phase 1 closed 2026-04-16. Next: Phase 2 — `../../docs/03-plans/01-phase-2-poc-generator-app.md` (PoC of the generator app — RubyLLM + Solid Queue + Roast).**
