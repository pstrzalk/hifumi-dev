---
date: 2026-05-11T21:39:00+0000
researcher: Paweł Strzałkowski
git_commit: 79deb8438b05401f4c914625d6c411796e0de16e
branch: main
repository: rails-app-generator
topic: "What went wrong on hifumi.dev: update_docs ‘Prompt is too long’ on Instruction 13 / Revision 41"
tags: [research, codebase, roast, revision_workflow, update_docs, w2_6, vendor_bundle, gitignore, hifumi.dev]
status: complete
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Research: What went wrong on hifumi.dev — update_docs "Prompt is too long" on Instruction 13 / Revision 41

**Date**: 2026-05-11T21:39:00+0000
**Researcher**: Paweł Strzałkowski
**Git Commit**: 79deb8438b05401f4c914625d6c411796e0de16e
**Branch**: main
**Repository**: rails-app-generator

## Research Question

The last generation run on hifumi.dev failed. `kamal logs` shows the failure in the Roast `update_docs` agent with `Prompt is too long` / `invalid_request`. Document — without proposing fixes — the prod evidence, the code path that built the failing prompt, and the workflow-side state that shaped it.

## Summary

On 2026-05-11 at 14:14:15 UTC, `ExecuteInstructionJob` running Instruction 13 (Project 20, "Event RSVP page with host login and minimalist look") crashed in step W2.6 of `lib/roast/revision_workflow.rb` while running `agent(:update_docs)` against the just-committed Revision 41 (position 2 of 6, prompt: scaffold Events + Devise auth). The job had already completed Revisions 39 and 40 successfully; Revisions 42–44 remain `pending` because `ExecuteInstructionJob#perform` `break`s the revision loop on first failure ([`app/jobs/execute_instruction_job.rb:19`](../../../../app/jobs/execute_instruction_job.rb#L19)).

The Roast error surface was:
```
agent(:update_docs) ❯ Prompt is too long
WARN agent(:update_docs) stdout_handler raised:
  Roast::Cogs::Agent::Providers::Claude::ClaudeInvocation::ClaudeFailedError - invalid_request
```

The prompt template that built the failing call is at [`lib/roast/revision_workflow.rb:288-325`](../../../../lib/roast/revision_workflow.rb#L288-L325). It embeds `git show --stat HEAD` (uncapped) and `git show HEAD` (capped at 16,000 chars) of the W2.5 commit. Direct inspection of Project 20's prod workspace shows the W2.5 commit `5bc7041` contains **8,617 files / 1,744,492 insertions**, with `git show --stat HEAD` alone weighing **538,153 chars / 8,624 lines** and `git show HEAD` weighing **69,335,983 chars**. The 16k truncation applies only to the body; the stat is embedded in full, taking the prompt past the model's context window.

The vendor-gem flood is sourced from a `.bundle/config` containing `BUNDLE_PATH: "vendor/bundle"` that exists in the prod workspace today (the skeleton ships only `BUNDLE_FROZEN: "true"`, so this was written during the revision), combined with a workspace `.gitignore` that does not exclude `vendor/bundle/` and a `git add -A` in W2.5 that has no path filter.

## Detailed Findings

### 1. Production evidence — the failed run

Pulled from prod via `kamal app exec` (`Rails.runner`):

- **Project 20** — "Event RSVP page with host login and minimalist look", user_id=1, created 2026-05-11 14:00:48 UTC.
- **Instruction 13** — phase `failed`, anchor_message_id 133, created 14:02:26, updated 14:14:16. `user_intent`: "Event RSVP page with host login and minimalist look. Hosts can create, edit, and manage events with RSVP deadlines. Guests can anonymously RSVP yes/no..."
- **Revisions** — 6 planned (positions 0–5):
  - **#0 (id 39)** — Event model. status=completed, wall=134.94s, sha `4c747ea`.
  - **#1 (id 40)** — GuestRsvp model. status=completed, wall=138.64s, sha `1284c51`.
  - **#2 (id 41)** — Events scaffold + Devise auth. **status=failed**, exit_code=1, wall=409.83s, metrics-sha `5bc7041` (column `git_sha` empty — set only on success at [`execute_instruction_job.rb:200`](../../../../app/jobs/execute_instruction_job.rb#L200)).
  - **#3 (id 42), #4 (id 43), #5 (id 44)** — status=pending, started_at empty. Never reached because of the revisions-loop break ([`execute_instruction_job.rb:19`](../../../../app/jobs/execute_instruction_job.rb#L19)).

Kamal logs at 14:14:07–14:14:16 show:
- `agent(:update_docs) Starting` at 14:14:07.376
- `agent(:update_docs) ❯ Prompt is too long` at 14:14:15.750 (8.4s after start)
- `stdout_handler raised: ClaudeFailedError - invalid_request` immediately after
- `agent(:update_docs) Complete` (Roast still logs Complete; the raise propagates out of the streaming handler)
- ExecuteInstructionJob: `Performed ExecuteInstructionJob (Job ID: ec1f8a49-...) from SolidQueue(generation) in 708538.84ms` — the whole job ran ~11m 48s.

Stack frame from the log: [`roast-ai-1.1.0/lib/roast/cogs/agent/providers/claude/claude_invocation.rb:122`](../../../../vendor/bundle/.../claude_invocation.rb#L122) raising `ClaudeFailedError` from `ClaudeInvocation#result`.

### 2. The state of the prod workspace at failure time

`Project.find(20).workspace_path` resolves to a directory on the prod host. Inspection shows (post-failure but pre-cleanup):

- **Top-level**: `.bundle/`, `.git/`, `.gitignore`, `.dockerignore`, `Gemfile`, `Gemfile.lock`, `Dockerfile`, `Procfile.dev`, `app/`, `bin/`, `config/`, `db/`, `docs/`, `lib/`, `log/`, `public/`, `script/`, `storage/`, `test/`, `tmp/`, `vendor/`.
- **`Gemfile`** owned by `generator` user, mtime 14:11 (rewritten during revision 41 by the agent — adds devise).
- **`.bundle/config`** (live content):
  ```yaml
  ---
  BUNDLE_FROZEN: "false"
  BUNDLE_PATH: "vendor/bundle"
  ```
  Skeleton ships only `BUNDLE_FROZEN: "true"` ([`lib/preview/skeleton/.bundle/config`](../../../../lib/preview/skeleton/.bundle/config)). The `BUNDLE_PATH` line and the `"false"` flip were written during Revision 41.
- **`.gitignore`** — the skeleton's, unmodified. Excludes `/.bundle`, `/log/*`, `/tmp/*`, `/storage/*`, `/public/assets`, `/config/master.key`. **Does not exclude `vendor/bundle/`**.
- **`vendor/bundle/`** — 339 MB, 8,601 files on disk.
- **`docs/` file sizes** (the only files `update_docs` is allowed to read):
  - `architecture.md` — 442 bytes / 14 lines
  - `conventions.md` — 67 bytes / 3 lines
  - `domain.md` — 503 bytes / 13 lines
  - `frontend.md` — 2,930 bytes / 71 lines
  - `revision_notes.md` — 710 bytes / 10 lines
- **Git log** (most recent 6 commits):
  ```
  5bc7041 Scaffold Events resource with host-only access control       ← HEAD (Revision 41)
  1284c51 docs: update manifest and revision notes                     ← Revision 40 docs commit
  04e4c9a Add GuestRsvp model for anonymous yes/no responses           ← Revision 40 code commit
  4c747ea docs: update manifest and revision notes                     ← Revision 39 docs commit
  2fab4ed Add Event model with host association and RSVP deadline ...  ← Revision 39 code commit
  3f045c9 docs: pick frontend template (office)                        ← pick_frontend_template
  ```
- **HEAD diff size**:
  - `git show --stat HEAD`: 8,624 lines / **538,153 chars**, summary line `8617 files changed, 1744492 insertions(+), 89 deletions(-)`.
  - `git show HEAD` (full body): **69,335,983 chars** (~69 MB).
- **CLAUDE.md presence (workspace and ancestors)**: none found at workspace root, none at `/var/lib/rails-app-generator/workspaces`, none at `/var/lib/rails-app-generator`, none at `/var/lib`, none at `/root/.claude/`. So Claude CLI auto-discovery contributes nothing on prod for this run.
- **`/root/.claude/projects/`**: does not exist on prod. No per-workspace auto-memory dirs.

### 3. Agent definition — `update_docs` per-cog config and prompt block

`lib/roast/revision_workflow.rb` defines the W2 workflow. Two pieces touch `update_docs`:

**Per-cog config** ([`lib/roast/revision_workflow.rb:55-58`](../../../../lib/roast/revision_workflow.rb#L55-L58)):
```ruby
agent(:update_docs) do
  model DOCS_MODEL
  command ["claude", "--tools", "Edit,Read"]
end
```
- `DOCS_MODEL` is `Roast::WorkflowEnv.docs_model`, default `"haiku"` ([`lib/roast/workflow_env.rb:23-31`](../../../../lib/roast/workflow_env.rb#L23-L31)).
- `command ["claude", "--tools", "Edit,Read"]` constrains the agent to Edit + Read at the Claude CLI flag level. Shipped in Phase 5 Step 2 (see prior plan).
- Inherits from the unnamed default `agent` block ([`revision_workflow.rb:36-42`](../../../../lib/roast/revision_workflow.rb#L36-L42)) for `provider :claude`, `working_directory WORKSPACE`, `skip_permissions!`, `show_stats!`.
- The comment at [`revision_workflow.rb:48-54`](../../../../lib/roast/revision_workflow.rb#L48-L54) explains `--bare` was previously here (to strip Claude Code's auto-memory, hooks, plugin sync, and `CLAUDE.md` auto-discovery), and was dropped 2026-05-04 because it also broke OAuth credential loading.

**Prompt block** ([`lib/roast/revision_workflow.rb:288-325`](../../../../lib/roast/revision_workflow.rb#L288-L325)):
```ruby
agent(:update_docs) do
  diff_stat = `cd #{Shellwords.escape(WORKSPACE)} && git show --stat HEAD`
  diff_body = `cd #{Shellwords.escape(WORKSPACE)} && git show HEAD`
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
    1. architecture.md — ...
    2. conventions.md — ...
    3. domain.md — ...
    4. frontend.md — Touch ONLY if this revision changed styling decisions. NEVER replace the entire file.
    5. revision_notes.md — APPEND a short section for this revision

    ## Rules — IMPORTANT, read carefully
    - Work from the diff above. Do NOT glob, do NOT read the workspace tree, do NOT inspect git history.
    - The only file reads allowed are these five exact paths: docs/architecture.md, docs/conventions.md, docs/domain.md, docs/frontend.md, docs/revision_notes.md.
    - Use Edit (small, targeted edits) or append-only operations.
    - If a doc has nothing to update for this revision, skip it.
    - Be terse. Each section in revision_notes is 1-3 sentences max.
  PROMPT
end
```

Critical: **`diff_stat` is interpolated unbounded** at the line `#{diff_stat}`. Only `diff_body` passes through the `[0, 16_000]` slice at [`revision_workflow.rb:293`](../../../../lib/roast/revision_workflow.rb#L293).

### 4. The claude CLI command line built by Roast

Per the subagent trace through `roast-ai-1.1.0/lib/roast/cogs/agent/providers/claude/claude_invocation.rb` (`#command_line`, lines 176–193):

For `update_docs`, the final argv assembled by Roast is:
```
["claude", "--tools", "Edit,Read",
 "-p", "--verbose", "--output-format", "stream-json",
 "--model", "haiku",
 "--dangerously-skip-permissions"]
```
- `--tools Edit,Read` from the per-cog `command` array.
- `-p --verbose --output-format stream-json` appended unconditionally by Roast.
- `--model haiku` from `config.valid_model` (resolved from `DOCS_MODEL`).
- `--dangerously-skip-permissions` because `apply_permissions?` is `false` via `skip_permissions!` on the default `agent` block.
- No `--bare` (removed 2026-05-04).
- No `--append-system-prompt` / `--replace-system-prompt` (not configured).

The prompt heredoc is written to the subprocess's stdin via `CommandRunner.execute` (`command_runner.rb:69-75`), inside `Bundler.with_unbundled_env`, with `chdir: WORKSPACE` and `PWD => WORKSPACE`.

### 5. Workflow control flow up to the crash

`lib/roast/revision_workflow.rb` `execute do ... end` ([`revision_workflow.rb:137-350`](../../../../lib/roast/revision_workflow.rb#L137-L350)) ran in order for Revision 41:

1. **W2.1 `log_start`** — prints summary, workspace, model.
2. **W2.2 `build_prompt`** — assembles codegen prompt: task + summary + manifest (`{architecture,conventions,domain,frontend}.md`) + workspace snapshot (sorted index of `app/controllers/`, `app/models/` + full bodies of `config/routes.rb` and `app/controllers/application_controller.rb`) + revision_notes.md + Rules.
3. **W2.3 `generate_code`** — claude CLI subprocess, prompt from W2.2. The agent added Devise: edited `Gemfile`, presumably ran `bundle config set --local path vendor/bundle` (or wrote `.bundle/config` directly), ran `bundle install`. Result: 339MB / 8,601 files under `vendor/bundle/`.
4. **W2.4 `verify`** — `VerifyRevision.run(WORKSPACE)`. Passed (no fail entries in the log around 14:13–14:14; metrics show the run reached W2.5 commit).
5. **W2.AR `auto_remediate`** — skipped because verify passed.
6. **W2.R `remediate`** — skipped because verify passed.
7. **W2.F `ensure_passing`** — passes through.
8. **W2.5 `git_commit`** — `cd <ws> && git add -A && git commit -m <summary>` ([`revision_workflow.rb:276-280`](../../../../lib/roast/revision_workflow.rb#L276-L280)). `git add -A` stages every untracked/modified file not excluded by `.gitignore`. With `vendor/bundle/` not ignored, all 8,601 vendored gem files were staged. Commit created: `5bc7041` with 8,617 files / 1,744,492 insertions. Log shows ~50,000 lines of `create mode 100644 vendor/bundle/...` chatter at 14:14:06–14:14:07.
9. **W2.6 `update_docs`** — block runs the two backtick subprocesses, builds the prompt with the un-capped 538KB `diff_stat`, sends it via stdin to the `claude` CLI. The Claude CLI / OpenRouter passes it to `anthropic/claude-haiku-4.5` (resolved via `ANTHROPIC_DEFAULT_HAIKU_MODEL` set by `bin/roast-openrouter` lines 1–17). The model returns `invalid_request: Prompt is too long`. Roast surfaces this via `ClaudeFailedError`.
10. **W2.7 `git_commit_docs`** and **W2.8 `report`** — never reached. The raised error exits the workflow non-zero.

Back in the job: `Open3.popen3` reports `exit_code=1`, the `ok` flag is false ([`execute_instruction_job.rb:235`](../../../../app/jobs/execute_instruction_job.rb#L235)), revision 41 is `update!(status: :failed, ...)` ([`execute_instruction_job.rb:209`](../../../../app/jobs/execute_instruction_job.rb#L209)), the `break if revision.failed?` at [line 19](../../../../app/jobs/execute_instruction_job.rb#L19) halts the revisions loop, the instruction is marked `phase: :failed` at [line 22](../../../../app/jobs/execute_instruction_job.rb#L22), and `ActiveSupport::Notifications.instrument("instruction.failed", ...)` fires.

### 6. How `vendor/bundle/` ends up tracked

Four pieces line up:

1. **Skeleton `.bundle/config`** ([`lib/preview/skeleton/.bundle/config`](../../../../lib/preview/skeleton/.bundle/config)) ships only `BUNDLE_FROZEN: "true"`. No `BUNDLE_PATH`. So a fresh `bundle install` from the skeleton baseline installs to the system GEM_HOME, not `vendor/bundle/`.
2. **Skeleton `.gitignore`** ([`lib/preview/skeleton/.gitignore`](../../../../lib/preview/skeleton/.gitignore)) does NOT ignore `vendor/bundle/`. It ignores `/.bundle` (the local config dir), `log/`, `tmp/`, `storage/`, `public/assets`, `config/master.key`.
3. **Init flow** ([`execute_instruction_job.rb:36-85`](../../../../app/jobs/execute_instruction_job.rb#L36-L85)) — copies skeleton + overlay, runs `bundle install --jobs 4` inside `Bundler.with_unbundled_env` ([line 63](../../../../app/jobs/execute_instruction_job.rb#L63)). The `with_unbundled_env` strips all `BUNDLE_*` from the parent ENV, so absent any local `.bundle/config` override, bundler installs to system GEM_HOME. Workspace baseline has no `vendor/bundle/`.
4. **What revision 41 changed** — the live `.bundle/config` on disk now reads `BUNDLE_PATH: "vendor/bundle"` / `BUNDLE_FROZEN: "false"`. Both keys were written during Revision 41 (Gemfile mtime 14:11 also matches). The `claude` CLI agent ran with `chdir: WORKSPACE` and no `BUNDLE_*` env (because Roast wraps the spawn in `Bundler.with_unbundled_env` at `command_runner.rb:69`). When the agent invoked `bundle install` after adding `devise` to the Gemfile, it presumably hit a permission failure writing to system GEM_HOME (the `generator` user can't write to `/usr/local/bundle`), then set `bundle config set --local path vendor/bundle` (or wrote the config directly) and re-ran. The 8,601 files materialised under `vendor/bundle/`.
5. **W2.5 commit step** ([`revision_workflow.rb:276-280`](../../../../lib/roast/revision_workflow.rb#L276-L280)) runs `git add -A` with no path filter. With `vendor/bundle/` not in `.gitignore`, all 8,601 files were staged and committed.

### 7. Sources of context the `update_docs` prompt receives

Single-revision, deterministic contributors at W2.6:
| Source | File / line | Cap |
|---|---|---|
| `kwarg(:revision_summary)` | [`revision_workflow.rb:296`](../../../../lib/roast/revision_workflow.rb#L296) | short string |
| `git show --stat HEAD` (diff_stat) | [`revision_workflow.rb:289, 301`](../../../../lib/roast/revision_workflow.rb#L289) | **none** |
| `git show HEAD` (diff_body) | [`revision_workflow.rb:290, 293, 305`](../../../../lib/roast/revision_workflow.rb#L293) | 16,000 chars |
| Task list + Rules text | [`revision_workflow.rb:308-324`](../../../../lib/roast/revision_workflow.rb#L308-L324) | static |

Tool-call growth across turns (Read tool against the 5 allowed paths):
| File | Allowed by | Cap |
|---|---|---|
| `docs/architecture.md` | prompt allowlist + `--tools Edit,Read` | none — grows monotonically across revisions |
| `docs/conventions.md` | same | none |
| `docs/domain.md` | same | none |
| `docs/frontend.md` | same | template ships at 50–100 lines; growth bounded informally |
| `docs/revision_notes.md` | prompt allowlist + prompt rule "APPEND a short section" | none — linear growth |

On this specific failed run, all five files were small (<3KB combined) — so growth-across-revisions was not a factor here. The blow-up is entirely from `diff_stat` (538KB) of the W2.5 commit.

Note: no `CLAUDE.md` was found in the workspace or any ancestor on prod, and `/root/.claude/projects/` is absent — so Claude CLI auto-discovery / auto-memory contributed nothing in this run despite `--bare` being absent.

### 8. The Roast runner wrappers

`ExecuteInstructionJob` selects between two wrappers ([`execute_instruction_job.rb:244-250`](../../../../app/jobs/execute_instruction_job.rb#L244-L250)):
- Production (or `FORCE_OPENROUTER=1`): [`bin/roast-openrouter`](../../../../bin/roast-openrouter). Sets `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN=$OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY=""`, `ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic/claude-opus-4.6`, `ANTHROPIC_DEFAULT_SONNET_MODEL=anthropic/claude-sonnet-4.6`, `ANTHROPIC_DEFAULT_HAIKU_MODEL=anthropic/claude-haiku-4.5`. `exec bundle exec roast "$@"`.
- Dev: [`bin/roast-claudesubscription`](../../../../bin/roast-claudesubscription). Unsets all six `ANTHROPIC_*` vars (so the `claude` binary uses OAuth from `~/.claude/`), pins PATH to `.ruby-version` via frum, `exec bundle exec roast "$@"`.
- Neither sets `--bare`, alters `HOME`, scrubs `~/.claude/`, or sets `CLAUDE_*` env vars.

So on prod, the `"haiku"` model alias resolved to `anthropic/claude-haiku-4.5` via the OpenRouter routing.

### 9. ENV passed to the Roast subprocess

[`execute_instruction_job.rb:173-178`](../../../../app/jobs/execute_instruction_job.rb#L173-L178):
```ruby
env = {
  "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
  "RAILS_APP_GENERATOR_MODEL"     => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet"),
  "OPENROUTER_API_KEY"            => api_key,
  "RAILS_ENV"                     => "development"
}
```
- `RAILS_APP_GENERATOR_DOCS_MODEL` and `RAILS_APP_GENERATOR_FIX_BUDGET_USD` are NOT forwarded; they fall through to `WorkflowEnv` defaults (`"haiku"`, `"0.50"`) — confirmed independently in [`thoughts/shared/research/2026-05-11/per-user-model-config-per-stage.md`](../per-user-model-config-per-stage.md).
- `OPENROUTER_API_KEY` is the per-user key from `revision.instruction.project.user.profile.openrouter_api_key` ([line 164](../../../../app/jobs/execute_instruction_job.rb#L164)).
- `RAILS_ENV=development` is forced for the subprocess tree because the generator container itself runs `RAILS_ENV=production` but the workspace is a fresh unconfigured Rails app.

## Code References

- `app/jobs/execute_instruction_job.rb:7-28` — `perform`: workspace init guards, revisions loop, break-on-failure, final phase computation, `instruction.*` notification.
- `app/jobs/execute_instruction_job.rb:36-85` — `init_rails_app`: skeleton + overlay copy, `bundle install --jobs 4`, `git init`, baseline commit.
- `app/jobs/execute_instruction_job.rb:141-158` — `init_docs_baseline`: writes 4 doc stubs (`frontend.md` excluded — created later by `pick_frontend_template`), `git commit --allow-empty`.
- `app/jobs/execute_instruction_job.rb:160-216` — `execute_revision`: env build, args build, subprocess spawn, status update (`completed` vs `failed`).
- `app/jobs/execute_instruction_job.rb:221-238` — `run_roast_subprocess`: `Open3.popen3`, per-line `LogScrub.call` before `Rails.logger.info`/`error`, exit_code extraction.
- `app/jobs/execute_instruction_job.rb:244-250` — `roast_executable`: production / `FORCE_OPENROUTER` switch.
- `lib/roast/revision_workflow.rb:25-28` — `WORKSPACE`, `CLAUDE_MODEL`, `DOCS_MODEL`, `FIX_BUDGET_USD` constants from `Roast::WorkflowEnv`.
- `lib/roast/revision_workflow.rb:36-42` — default `agent` config (provider, model, working_directory, skip_permissions!, show_stats!).
- `lib/roast/revision_workflow.rb:48-54` — comment documenting `--bare` removal on 2026-05-04.
- `lib/roast/revision_workflow.rb:55-58` — `agent(:update_docs)` per-cog config (`model DOCS_MODEL`, `command ["claude", "--tools", "Edit,Read"]`).
- `lib/roast/revision_workflow.rb:66` — `ruby(:ensure_passing) { abort_on_failure! }` (Phase 5 Step 2 shipping).
- `lib/roast/revision_workflow.rb:75-77` — `agent(:fix)` per-cog config with `--max-budget-usd FIX_BUDGET_USD`.
- `lib/roast/revision_workflow.rb:146-201` — W2.2 `build_prompt`: manifest glob, `revision_notes.md`, workspace snapshot, Rules.
- `lib/roast/revision_workflow.rb:204-206` — W2.3 `agent(:generate_code)`.
- `lib/roast/revision_workflow.rb:209-221` — W2.4 `verify`.
- `lib/roast/revision_workflow.rb:227-251` — W2.AR `auto_remediate`.
- `lib/roast/revision_workflow.rb:254-258` — W2.R `repeat(:remediate)`.
- `lib/roast/revision_workflow.rb:261-271` — W2.F `ensure_passing` with `git reset --hard HEAD && git clean -fd` on fail.
- `lib/roast/revision_workflow.rb:276-280` — W2.5 `cmd(:git_commit)` running `git add -A && git commit -m <summary>`. **No path filter on `git add -A`.**
- `lib/roast/revision_workflow.rb:288-325` — W2.6 `agent(:update_docs)` prompt block. **`diff_stat` unbounded, `diff_body` capped at 16k chars.**
- `lib/roast/revision_workflow.rb:328-336` — W2.7 `cmd(:git_commit_docs)`.
- `lib/roast/revision_workflow.rb:339-349` — W2.8 `ruby(:report)`.
- `lib/roast/workflow_env.rb:16-17` — `WORKSPACE` from `RAILS_APP_GENERATOR_WORKSPACE` (required).
- `lib/roast/workflow_env.rb:23` — `CLAUDE_MODEL`, default `"sonnet"`.
- `lib/roast/workflow_env.rb:28-31` — `DOCS_MODEL`, default `"haiku"`. Comment notes switch from `sonnet` (commit `13f22a8`) for ~$0.5/revision savings.
- `lib/roast/workflow_env.rb:46-49` — `FIX_BUDGET_USD`, default `"0.50"`, validated via `Float(raw)`.
- `lib/preview/skeleton/.bundle/config` — ships `BUNDLE_FROZEN: "true"` only.
- `lib/preview/skeleton/.gitignore` — does not include `vendor/bundle/`.
- `bin/roast-openrouter:1-17` — ENV setup for OpenRouter routing.
- `bin/roast-claudesubscription:1-29` — ENV scrub + PATH pin for subscription auth.

## Architecture Documentation

### W2 revision-workflow steps as currently coded

```
W2.1 log_start         (Ruby)   — print summary, workspace, model
W2.2 build_prompt      (Ruby)   — assemble codegen prompt
W2.3 generate_code     (Agent)  — claude CLI subprocess; tool-unrestricted
W2.4 verify            (Ruby)   — VerifyRevision.run; fail! → state[:verify_errors]
W2.AR auto_remediate   (Ruby)   — skip if verify passed; deterministic recipes; fail! → next
W2.R repeat(remediate) (Loop)   — agent(:fix) + reverify, max 2 iters
W2.F ensure_passing    (Ruby)   — git reset --hard + git clean -fd on fail; abort_on_failure!
W2.5 git_commit        (Cmd)    — git add -A && git commit
W2.6 update_docs       (Agent)  — claude CLI, model DOCS_MODEL (haiku), --tools Edit,Read
W2.7 git_commit_docs   (Cmd)    — git add docs/ && git commit (allow-empty)
W2.8 report            (Ruby)   — final SHA, status
```

`update_docs` runs only after W2.5 succeeds. The prompt source for `update_docs` is exclusively the diff of the W2.5 commit — no manifest splice (unlike W2.2). `update_docs` reads the 4 manifest files + `revision_notes.md` itself via its `Read` tool calls inside its own session.

### Two distinct prompt-growth surfaces in W2

| Surface | Where built | Inputs that grow per revision |
|---|---|---|
| W2.2 `build_prompt` (codegen) | [`revision_workflow.rb:146-201`](../../../../lib/roast/revision_workflow.rb#L146-L201) | Manifest (4 .md files), revision_notes.md, workspace snapshot (controllers/models index + routes.rb + application_controller.rb full bodies) |
| W2.6 `update_docs` block | [`revision_workflow.rb:288-325`](../../../../lib/roast/revision_workflow.rb#L288-L325) | `git show --stat HEAD` (uncapped), `git show HEAD` (16k cap), + tool-call reads of 5 doc files during the session |

The failed run blew up on the W2.6 surface, specifically the unbounded `diff_stat` slot, with growth driven by the **single-commit file count** rather than cross-revision accumulation.

## Historical Context (from thoughts/)

- `docs/09-ideas/03-docs-and-knowledge-management.md` — 2026-05-01 analysis of W2.6 cost growth from a 6-revision smoke run. Documents `revision_notes.md` unbounded growth (6.91k → 7.47k tokens across 6 revs in that run) and lists options A–F (cap revision_notes feed, heuristic doc-routing, deterministic notes, drop architecture.md, drop docs entirely, separate user-artifact from workflow-memory). Decision was to **wait for more sample apps** before redesigning. None of A–F shipped. All of these mechanisms are still active in the current code.

- `thoughts/shared/plans/2026-05-01/phase-5-step-2-revision-workflow-waste.md` — three mitigations that DID ship as a consequence of a different production failure (`tmp/simple_application_run_kamal.log`): (a) `ruby(:ensure_passing) { abort_on_failure! }` at [`revision_workflow.rb:66`](../../../../lib/roast/revision_workflow.rb#L66), (b) `--tools Edit,Read` on `update_docs` at [line 57](../../../../lib/roast/revision_workflow.rb#L57), (c) `--max-budget-usd` on `agent(:fix)` at [line 76](../../../../lib/roast/revision_workflow.rb#L76). The plan's `--bare` proposal was later reversed (2026-05-04) due to OAuth breakage; the system-reminder bloat that `--bare` was meant to suppress is therefore a known accepted cost.

- `thoughts/shared/plans/2026-05-02/randomized-design-systems-for-generated-apps.md` — added `frontend.md` to the W2.6 prompt scope (allowed-paths and "touch only if styling changed" rule) and the W2.2 manifest glob. Active in current code.

- `thoughts/shared/research/2026-05-11/per-user-model-config-per-stage.md` — independent confirmation that `RAILS_APP_GENERATOR_DOCS_MODEL` is not threaded through `ExecuteInstructionJob`'s subprocess env hash, so `update_docs` always resolves to `"haiku"` regardless of any ENV in the job process. Documents the three named-agent configs (default, `:fix`, `:update_docs`) and the OpenRouter alias resolution.

- `thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md` — corroborates that `--tools Edit,Read` was active before `--bare` was dropped, and that `frontend.md` keep-in-sync via `update_docs` was working at the templates Phase 4-5 smoke.

## Related Research

- [`thoughts/shared/research/2026-05-11/per-user-model-config-per-stage.md`](../per-user-model-config-per-stage.md) — six-call-site LLM model-routing audit (today's earlier research).
- [`thoughts/shared/plans/2026-05-01/phase-5-step-2-revision-workflow-waste.md`](../../../plans/2026-05-01/phase-5-step-2-revision-workflow-waste.md) — origins of the current `update_docs` + `ensure_passing` + `fix` cog configs.
- [`docs/09-ideas/03-docs-and-knowledge-management.md`](../../../../docs/09-ideas/03-docs-and-knowledge-management.md) — cost/structure analysis of the W2.6 docs surface.
- [`docs/02-architecture/01-workflows-and-decisions.md`](../../../../docs/02-architecture/01-workflows-and-decisions.md) — W2.1–W2.8 + W2.R + W2.F canonical step definitions.

## Open Questions

(Documenting questions that arose during research — not recommendations.)

1. Whether the `claude` agent at W2.3 wrote `BUNDLE_PATH: "vendor/bundle"` into `.bundle/config` explicitly (via `bundle config set --local path vendor/bundle`) or by direct `.bundle/config` edit — the live workspace file proves the state but not the mechanism. The kamal log slice retrieved here did not capture the W2.3 turn-by-turn for revision 41.
2. Whether the existing `ensure_passing` reset path ([`revision_workflow.rb:267`](../../../../lib/roast/revision_workflow.rb#L267)) — `git reset --hard HEAD && git clean -fd` — runs in this specific failure mode. It triggers on the W2.F `fail!` path, but the W2.6 `ClaudeFailedError` is raised, not `fail!`'d — so the reset does not appear to run, and the workspace remained in the post-W2.5 state (8,601 files in vendor/bundle, commit `5bc7041` present in git log) when inspected at 21:39 UTC.
3. Whether `Open3.popen3` reports `exit_code=1` when the Roast subprocess crashes via uncaught exception in a streaming handler (vs a clean non-zero exit). The DB row shows `exit_code: 1` and the job correctly marked revision 41 as `:failed`, but the exact exit-code mechanism from Roast's perspective wasn't verified here.
