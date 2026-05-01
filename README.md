# Rails App Generator

Generate a complete Rails application from a natural-language prompt. Output is a clean Rails repo (your own git history, your own dependencies — no vendor lock-in).

## Requirements

- Ruby 4.0.2 (pinned in `.ruby-version`; install with `frum install 4.0.2`)
- SQLite
- Docker (any recent Desktop or Engine; verify with `docker --version`) — required for the preview pane
- Claude CLI logged in (`claude login`) — used by the per-revision implementation step on the subscription plan
- Optional: `OPENROUTER_API_KEY` in env — needed only for the paid `bin/roast-openrouter` runner

## Setup

```sh
bin/setup
```

Installs gems, creates the dev DB, and prepares Solid Queue.

## Pipeline at a glance

```
user message in chat
      │
      ▼
[1] ChatRespondJob          assistant turn; chat-LLM may call `start_generation`
      │
      ▼
[2] StartGeneration tool ─► CreatePlan          plan-LLM expands intent into N revisions
      │
      ▼
[3] ExecuteInstructionJob   workspace bootstrap (rails new, scaffolding) + per-revision loop
      │
      ▼
[4] bin/roast workflow      implement → verify (rails test) → commit, with remediation
```

Each CLI entry point below covers one or more of these stages. Pick the one that matches what you want to drive.

## Run via the UI (real, end-to-end)

Start the full dev stack (web + Tailwind watcher + Solid Queue worker — see `Procfile.dev`):

```sh
bin/dev
```

Open <http://localhost:3000>:

1. Click **New project** and describe what to build, e.g. *"Personal blog with posts and comments"*.
2. The chat assistant streams a reply. If it asks for clarification, answer briefly.
3. Once it calls `start_generation`, three or more revision cards appear and run live (`pending → generating → completed`).
4. Final `✅ Generation finished.` Output lives at `~/projects/rails-app-generator-workspaces/project_<id>/`.

## Running previews locally

Each project has a **▶ Start preview** button on its page. Clicking it launches the generated app in a hardened Docker container; the iframe loads at `http://localhost:#{3000 + project.id}` once the in-container Rails responds on `/up`.

One-time setup:

```sh
bin/preview-rebuild-base   # builds preview-base:latest (~2-4 min on a clean Docker)
```

Re-run `bin/preview-rebuild-base` after any change to `lib/preview/skeleton/Gemfile`. Re-run `bin/preview-regen-skeleton` to bump Rails (rare).

Notes:

- Per-project build is fast on a warm cache (10-30 s); first build with cold base image is 2-4 min.
- Idle previews auto-stop after 30 min (`CleanupIdlePreviewsJob`, every 5 min).
- A new generation auto-stops the running preview first (containers don't autoload prod-mode code).
- Troubleshooting: `docker logs preview-<project_id>` for in-container logs; `docker ps --filter name=preview-` to list active previews; `docker network inspect preview-internal` to inspect the shared network.

## Run via the CLI

### Whole pipeline, deterministic — `bin/generate full`

Bypasses the chat-LLM and plan-LLM. Uses a hardcoded plan fixture, then runs the real `bin/roast` subprocess for each revision.

```sh
bin/generate full --prompt "Simple todo list, Tailwind"
bin/generate full --prompt "..." --plan todo_list   # explicit fixture
```

Plan fixtures live in `test/fixtures/plans/` (currently: `todo_list`). Add new ones by defining `PlanFixtures.<name>` returning a `CreatePlan::Result`.

The `--prompt` is stored on the project name and instruction intent; the actual revisions executed always come from the named plan. This is a debug tool, not a free-form generator — for free-form, use the UI.

### Re-run the assistant turn — `bin/generate respond`

```sh
bin/generate respond --project-id 42
```

Re-runs `ChatRespondJob.perform_now` against the project's latest user message. Burns chat-LLM tokens. Useful if the previous turn errored or you want to retry.

### Re-run instruction execution — `bin/generate execute`

```sh
bin/generate execute --instruction-id 99
```

Synchronous `ExecuteInstructionJob.perform_now`. Runs every revision of the instruction from `position 0` upwards; the loop stops on the first failure. There is no built-in skip for already-completed revisions, so this is **not** a retry tool — re-running an instruction whose revisions previously succeeded will re-execute their prompts against the current workspace state. To retry a partially failed instruction, reset the workspace (or just the failing revision's commits via `git reset`) before re-running. Useful for debugging the W2 chain without a Solid Queue worker.

### Run one Roast workflow directly — `bin/roast`

The lowest level. The args mirror what `ExecuteInstructionJob` produces; the workspace must already exist.

```sh
bin/roast lib/roast/revision_workflow.rb -- \
  revision_id=N \
  revision_summary='Add Todo model' \
  revision_prompt='Create a Todo model with title, body...'
```

Use this when you want to iterate on a single Roast workflow file without going through DB-backed orchestration. Switch to `bin/roast-openrouter` for the paid per-token runner (needs `OPENROUTER_API_KEY`).

### Drive stages by hand from the console — `bin/rails console`

Stages with no dedicated CLI:

```ruby
# Stage 2 in isolation: plan-LLM only
result = CreatePlan.call(intent: "blog with posts and comments", clarifications: {}, context: {})
result.instruction_description
result.revisions   # => [{ summary:, prompt: }, ...]

# Stage 1 setup: create a project + chat + first user message
project = Project.create!(name: "blog demo")
chat = GeneratorAgent.create!(project: project)
chat.messages.create!(role: :user, content: "Personal blog with posts and comments")
# then: bin/generate respond --project-id <project.id>

# Skip the chat turn: invoke the StartGeneration tool the same way the chat-LLM would.
# Creates an instruction + revisions and emits `instruction.requested`, which the
# worker (or :inline adapter) picks up to run ExecuteInstructionJob.
StartGeneration.new(project: project).execute(intent: "blog", clarifications: {})
```

### Watch live progress — `bin/watch-instruction`

```sh
bin/watch-instruction          # watches Instruction.last
bin/watch-instruction 42       # watches instruction #42
```

Polls every 2s and prints status per revision. Equivalent to the live revision cards in the UI.

### Run a single instruction synchronously — `bin/execute-instruction`

```sh
bin/execute-instruction 99
```

Thin wrapper around `ExecuteInstructionJob.perform_now(99)`. Same caveats as `bin/generate execute --instruction-id 99` (no skip for already-completed revisions; not a retry tool).

### Inspect a wedged chat — `bin/inspect-chat`

```sh
bin/rails runner bin/inspect-chat 15                                # local
kamal app exec --primary "bin/rails runner bin/inspect-chat 15"     # against prod
```

Dumps a project's chat messages and `tool_calls` rows in order, then runs a structural pairing analysis (every `tool_result` must follow its matching assistant `tool_use`). Use when the chat fails with `RubyLLM::BadRequestError` ("unexpected `tool_use_id`...") — the dump tells you whether a tool was called twice in one turn or a tool_result is orphaned.

### Run the test suite

```sh
bin/rails test                        # unit + integration; gated tests below are skipped by default
E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb
E2E_PREVIEW=1  bin/rails test test/integration/preview_lifecycle_test.rb
```

`E2E_GENERATE=1` runs the real `bin/roast` subprocess and burns Claude tokens (~15 min wall). `E2E_PREVIEW=1` exercises the full Docker preview chain locally — no LLM calls, just `docker build`/`run`/`curl`/`rm` (~30-60 s on a warm base image; requires `bin/preview-rebuild-base` to have run once). Both are gated so the default suite stays fast.

## Inspect generated output

Generated apps live at `$RAILS_APP_GENERATOR_WORKSPACE_ROOT/project_<id>/` (default: `~/projects/rails-app-generator-workspaces/project_<id>/`).

```sh
WS=~/projects/rails-app-generator-workspaces/project_42

cd "$WS" && git log --oneline       # one commit per revision + scaffolding baseline + rails-new initial
cd "$WS" && bin/rails test          # generated app's own test suite
cd "$WS" && bin/rails server        # try the generated app

cat "$WS/docs/domain.md"            # generator-maintained: glossary + business rules
cat "$WS/docs/conventions.md"       # patterns the generator applied
cat "$WS/docs/revision_notes.md"    # per-revision decision log
```

## Reset / clean up

| What | How |
|------|-----|
| Dev DB | `bin/rails db:drop db:setup` |
| One generated app | `rm -rf ~/projects/rails-app-generator-workspaces/project_<id>` |
| Stuck instruction | `bin/rails runner "Instruction.find(N).update!(phase: :failed)"` |
| Solid Queue jobs | `bin/rails runner "SolidQueue::Job.delete_all"` |

## Configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `RAILS_APP_GENERATOR_WORKSPACE_ROOT` | `~/projects/rails-app-generator-workspaces` | Where generated apps live. The test suite overrides to `Dir.tmpdir`. |
| `RAILS_APP_GENERATOR_MODEL` | `sonnet` | Claude model for the per-revision Roast subprocess. |
| `E2E_GENERATE` | unset | Set to `1` to opt the gated end-to-end generation test in. |
| `E2E_PREVIEW` | unset | Set to `1` to opt the gated preview-lifecycle Docker test in. |
| `OPENROUTER_API_KEY` | unset | Required by `bin/roast-openrouter`. |

## Roast runner choice

`ExecuteInstructionJob` picks one of two wrappers based on environment:

- `bin/roast-claudesubscription` — dev default. Uses the local `claude` CLI's OAuth subscription. Free given a paid Claude plan; throttled by the plan's quota. The wrapper unsets `ANTHROPIC_*` env vars and pins frum's Ruby on PATH.
- `bin/roast-openrouter` — production default (and dev when `FORCE_OPENROUTER=1`). Uses OpenRouter's Anthropic-compatible API. Paid per-token; needs `OPENROUTER_API_KEY`.

`bin/roast` itself is the bundler binstub (`bundle exec roast` raw, no env setup) — for direct testing only. Don't rely on it from `ExecuteInstructionJob`.

## Development of the generator itself

The generator is a Rails 8 app with RubyLLM + Solid Queue. Phase notes and the active plan live under `docs/`; start at `docs/03-plans/` for what's in flight. See `CLAUDE.md` for status, conventions, and the canonical reading order.

The visible UI follows the **Hifumi design system** — warm paper background, IBM Plex stack, Rails-red accent, rectangular outlined status tags. Tokens and component classes live in `app/assets/tailwind/application.css`; the full reference (token map, component-to-view inventory, voice rules, anti-patterns) is at `docs/02-architecture/04-design-system.md`. Read it before redesigning any chrome.
