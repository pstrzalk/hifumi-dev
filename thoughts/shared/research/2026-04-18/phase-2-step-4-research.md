---
date: 2026-04-18T16:32:36+02:00
researcher: Paweł Strzałkowski
git_commit: 85ede915d969cc355cdf85057ca941daf3791006
branch: phase-2-step-3-chat-baseline
repository: rails-app-generator
topic: "Phase 2 Step 4 — codebase state before adding StartGeneration/SuggestPrompts tools + CreatePlan service"
tags: [research, codebase, phase-2, step-4, ruby_llm, tools, create_plan]
status: complete
last_updated: 2026-04-18
last_updated_by: Paweł Strzałkowski
---

# Research: Phase 2 Step 4 — codebase state before tools + CreatePlan

**Date**: 2026-04-18T16:32:36+02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: 85ede915d969cc355cdf85057ca941daf3791006
**Branch**: phase-2-step-3-chat-baseline
**Repository**: rails-app-generator

## Research Question

What is the current state of the codebase with respect to Phase 2 Step 4 — adding the `StartGeneration` and `SuggestPrompts` RubyLLM tools plus the `CreatePlan` service? What already exists, what is empty-but-reserved, and what schema/plumbing does Step 4 build on?

## Summary

Step 3 (chat baseline) has landed through three commits (`f3010ed`, `15f7fd7`, `85ede91`). The chat loop works end-to-end: `ProjectsController#create` → `MessagesController#create` → `ChatRespondJob#perform` calls `chat.complete` with streaming and broadcasts assistant chunks via Turbo. Tool infrastructure directories (`app/tools/`, `app/agents/`, `app/prompts/`, `app/schemas/`) exist as `.gitkeep`-only placeholders. `app/services/` does **not** exist at all. No `ActiveSupport::Notifications.instrument` or `.subscribe` calls exist in `app/` or `config/`. The `ToolCall` model from `rails g ruby_llm:install` is in place. The Instruction/Revision schema present today diverges from Step 4's pseudocode on several columns — documented below.

## Detailed Findings

### Chat baseline (Step 3) — the platform Step 4 extends

**ProjectsController** (`app/controllers/projects_controller.rb`)
- `new` (lines 2-4): renders empty form.
- `create` (lines 6-21): validates description presence, creates `Project` (name truncated to 60 chars, line 15), `Chat` (line 16), first user `Message` (line 17), enqueues `ChatRespondJob` (line 18), redirects to show (line 20).
- `show` (lines 23-26): loads `@project.chat.messages.order(:created_at)`.

**MessagesController** (`app/controllers/messages_controller.rb`)
- `create` (lines 2-21): validates content, renders `turbo_stream.replace` of the form frame on both blank and success paths. Creates user message and enqueues `ChatRespondJob`. No redirect on Turbo path (per `project_form_replace_over_redirect` memory).

**ChatRespondJob** (`app/jobs/chat_respond_job.rb`)
- `perform` (lines 4-22): finds message, gets chat, calls `chat.complete do |chunk| … end` (line 9). Streaming loop accumulates content into the assistant row via `update_columns` (line 14, bypasses callbacks) and broadcasts `broadcast_replace` per chunk (line 15). Assistant row is lazily fetched via `latest_assistant(chat)` (line 27: `chat.messages.where(role: :assistant).order(:id).last`) — RubyLLM auto-creates the row via `on_new_message`. Error branch (lines 17-21) creates/updates an assistant message with error text.
- `broadcast_replace` helper (lines 30-37) targets `dom_id(message)` with explicit `partial: "messages/message"` (per `project_ruby_llm_partial_path` memory).
- **No `tools:` argument passed to `chat.complete`**. **No system prompt set.** **No `Current.project` assignment.**

**Views**
- `app/views/projects/show.html.erb:2` — `turbo_stream_from @project` (project is the stream identifier).
- `app/views/projects/show.html.erb:6` — `id="messages"` container at the append target.
- `app/views/messages/_message.html.erb:1` — wrapper uses `dom_id(message)`; renders `role` + `content`.
- `app/views/messages/_form.html.erb:1` — form `id: dom_id(project, :message_form)`, posts to `project_messages_path(project)`.

**Models**
- `app/models/project.rb:1-11` — `has_one :chat`; `has_many :instructions`; `has_many :revisions`; `workspace_path` method at lines 8-10 derives `"storage/workspaces/#{id}"`. **No `acts_as_*`, no `workspace_initialized?` method.**
- `app/models/chat.rb:1-5` — `acts_as_chat`, `belongs_to :project`.
- `app/models/message.rb:1-15` — `acts_as_message`, `has_many_attached :attachments`, `after_create_commit :broadcast_append_message` broadcasting to `chat.project` stream, target `"messages"`, explicit `partial: "messages/message"`.
- `app/models/tool_call.rb:1-3` — `acts_as_tool_call`.

**RubyLLM initializer** (`config/initializers/ruby_llm.rb:1-7`)
- `openrouter_api_key` from ENV/credentials.
- `default_model = "anthropic/claude-haiku-4.5"`.
- `use_new_acts_as = true`.
- No global tool registration. No `default_system_instructions`.

### Data model currently on disk vs. Step 4 pseudocode

Step 4's pseudocode in the plan references several columns that do **not** yet exist in the migrations shipped by Step 2. Step 4 will need either schema changes or code adjustments.

**Instruction** (`app/models/instruction.rb:1-16`, migration `db/migrate/20260418092030_create_instructions.rb`)
- Columns present: `project_id`, `anchor_message_id`, `phase` (default `"researching"`), `description`, `research_output`, timestamps.
- Enum `phase`: `researching`, `planning`, `implementing`, `completed`, `failed`, `cancelled`.
- **Not present** (plan references them): `user_intent: text`; `phase: :processing` value.
- Validation: `description` presence.
- Associations: `belongs_to :project`, `belongs_to :anchor_message` (`class_name: "Message"`), `has_many :revisions` (dependent destroy).

**Revision** (`app/models/revision.rb:1-16`, migration `db/migrate/20260418092038_create_revisions.rb`)
- Columns present: `project_id`, `instruction_id`, `parent_id` (optional, nullify), `git_sha`, `summary`, `position` (unique per instruction_id), `status` (default `"pending"`), timestamps.
- Enum `status`: `pending`, `generating`, `completed`, `failed`.
- **Not present** (plan references them): `prompt: text`, `started_at`, `finished_at`, `metrics: jsonb`.
- Validations: `position` presence + integer >= 0; `summary` presence.

**Project** (`app/models/project.rb`, migrations `20260418091957_create_projects.rb` + `20260418151522_remove_workspace_path_from_projects.rb`)
- Columns: `name` (null: false), timestamps. `workspace_path` was added then removed — now derived via method.

**Chat / Message / ToolCall** (migrations `20260418091916_create_chats.rb`, `20260418091917_create_messages.rb`, `20260418091918_create_tool_calls.rb`, `20260418091920_add_references_to_chats_tool_calls_and_messages.rb`)
- `Message` columns: `role`, `content`, `content_raw` (json), `thinking_text`, `thinking_signature`, `thinking_tokens`, `input_tokens`, `output_tokens`, `cached_tokens`, `cache_creation_tokens`; FKs `chat_id`, `model_id`, `tool_call_id` added later.
- `ToolCall` columns: `tool_call_id` (unique), `name`, `thought_signature`, `arguments` (json default `{}`).
- Role enum handled by `acts_as_message`, not declared explicitly.

**Fixtures** (`test/fixtures/`)
- `projects.yml` — single `flowers` project.
- `chats.yml` — `flowers` chat on that project.
- `messages.yml` — three messages: `first_user`, `first_assistant`, `start_generation` (assistant, content `"[tool call: StartGeneration]"`).
- `instructions.yml` — `flowers_v1`, phase `implementing`.
- `revisions.yml` — `flowers_v1_step1` (position 0, status completed, sha `"aaaaaaa"`), `flowers_v1_step2` (position 1, status pending, parent step1).

**Model tests** (`test/models/`)
- `instruction_test.rb` — fixture validity, phase default, enum accept/reject, presence, cascade delete (6 cases).
- `revision_test.rb` — fixture validity, status default, parent, status enum, presence, unique position (6 cases).
- `project_test.rb` — fixture validity, name presence, `workspace_path` derivation, associations, cascade delete (5 cases).
- `chat_test.rb` — project association + presence (2 cases).
- `message_test.rb` — Turbo broadcast on create: enqueue, single broadcast, append action with target + partial (3 cases).

### RubyLLM tool infrastructure — reserved, empty

- `app/tools/` — only `.gitkeep`. No tool classes.
- `app/prompts/` — only `.gitkeep`.
- `app/schemas/` — only `.gitkeep`.
- `app/agents/` — only `.gitkeep`.
- `app/services/` — **directory does not exist**. No `CreatePlan` service or any service class.

### Event bus — not wired yet

- No `ActiveSupport::Notifications.instrument(...)` calls anywhere in `app/`.
- No `ActiveSupport::Notifications.subscribe(...)` calls in `config/initializers/` or elsewhere.
- Step 4 introduces the first instrument (`"instruction.requested"` inside `StartGeneration#execute`) and the first subscriber (in `config/initializers/event_subscribers.rb`, per Step 6 — though the Step 4 pseudocode in the plan puts the `ExecuteInstructionJob.perform_later` subscriber directly under Step 4 bullet 5).

### Reference: tool + prompt shape (from docs and spike)

**Tool contract expected** (per plan pseudocode `docs/03-plans/01-phase-2-poc-generator-app.md:246-292` and user journey `docs/01-vision/02-user-journey.md:27-34`)
- Inherit `RubyLLM::Tool`; declare `description "..."`; declare `param :name, type:, desc:`; define `execute(**kwargs)` returning a Hash (becomes the tool result persisted as `role: :tool` Message).
- Passed to chat as **classes**: `chat.ask(content, tools: [StartGeneration, SuggestPrompts])`.

**Revision prompt shape produced by CreatePlan** must match the structure consumed in the spike at `spikes/roast/revision_workflow.rb:84-116`:
- Roast `build_prompt` builds a markdown document with `## Task` (from `kwarg(:revision_prompt)`), `## Summary` (from `kwarg(:revision_summary)`), then optionally `## Current application state (manifest)` and `## Context from previous revisions`, then a fixed `## Rules` block (Rails Way / Tailwind / Hotwire / Minitest).
- Consequence: `Revision#prompt` is the body that ends up under `## Task`; `CreatePlan::AdHocLLM` does **not** need to repeat the rules block — Roast appends it.

### Test patterns already in place to mimic for Step 4

**Stubbing `chat.complete`** in `test/jobs/chat_respond_job_test.rb:82-103`
- `Chat.class_eval` + `alias_method` pattern with `ChatCompleteStub` holding `chunks`, `raise_at`, `raise_immediately`.
- Yields `OpenStruct.new(content: delta)` per chunk; creates the assistant row manually inside the stub.
- Step 4 can extend this pattern to stub a `StartGeneration` tool call instead of plain streaming.

## Code References

- `app/controllers/projects_controller.rb:6-21` — project creation flow that seeds the chat + first user message.
- `app/controllers/messages_controller.rb:2-21` — Turbo-stream form replace on both blank and success.
- `app/jobs/chat_respond_job.rb:4-22` — current streaming chat loop (no tools, no system prompt, no `Current.project`).
- `app/jobs/chat_respond_job.rb:27` — `latest_assistant` helper.
- `app/models/message.rb:5-14` — `after_create_commit` broadcast with explicit partial.
- `app/models/tool_call.rb:1-3` — `acts_as_tool_call`.
- `config/initializers/ruby_llm.rb:1-7` — OpenRouter + Haiku 4.5 config, `use_new_acts_as = true`.
- `db/migrate/20260418092030_create_instructions.rb` — current Instruction schema (no `user_intent`).
- `db/migrate/20260418092038_create_revisions.rb` — current Revision schema (no `prompt`, `started_at`, `finished_at`, `metrics`).
- `db/migrate/20260418091918_create_tool_calls.rb:3-15` — ToolCall table.
- `spikes/roast/revision_workflow.rb:84-116` — prompt assembly (shape constraint on `Revision#prompt`).
- `test/jobs/chat_respond_job_test.rb:82-103` — stubbing harness usable for tool tests.

## Architecture Documentation

- **Layer boundaries (from plan)**: RubyLLM lives in `ChatRespondJob` and tool `execute` methods; Roast lives in `ExecuteInstructionJob` (not yet implemented) as subprocess; `ActiveSupport::Notifications` is the only bridge. Step 4 introduces the first notification (`instruction.requested`) and its first subscriber.
- **Tool arg discipline (A7)**: the chat LLM only receives plain-language `intent` + `clarifications`; detailed revision prompts never leave the backend. `CreatePlan::AdHocLLM`'s system prompt (the "secret sauce") stays server-side.
- **Abstraction (A6)**: `CreatePlan.call(intent:, clarifications:, context:)` delegates to `CreatePlan.implementation` (initially `AdHocLLM`), returning an array of hashes ready for `Revision.create!`.
- **W2.3 agent prompt invariants** (`docs/02-architecture/01-workflows-and-decisions.md:125-135`) that `CreatePlan::AdHocLLM` must satisfy: (1) workspace assumed initialized; (2) no "Claude"/"Anthropic" tokens unless the user intent requires Anthropic integration; (3) concrete tasks, not meta. Step 5's `ExecuteInstructionJob` is what guarantees #1 at runtime.
- **Partial-path gotcha** (memory `project_ruby_llm_partial_path`): RubyLLM's `acts_as_message` overrides `to_partial_path` per role; every render/broadcast must pass explicit `partial:`. Already applied in `Message#broadcast_append_message` and `ChatRespondJob#broadcast_replace`.
- **Form-replace over redirect** (memory `project_form_replace_over_redirect`): `MessagesController` responds with `turbo_stream.replace` of the form, not a redirect. Step 4 does not introduce a new form.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md` — Step 3 detailed plan. Explicitly **rejects `Current.project`** in favor of instance-scoped tools instantiated as `StartGeneration.new(project: project)` inside `ChatRespondJob`. Pre-wires the job to derive project via `message.chat.project`. Notes that `app/tools/`, `app/agents/`, `app/prompts/`, `app/schemas/` are reserved placeholders for Step 4+. Bakes RubyLLM streaming in from the start; Step 4 bolts tools onto the existing streaming loop without changing it. No system prompt in Step 3 — arrives in Step 4 "when tools need behavior discipline."
- `thoughts/shared/plans/` contains **no separate Step 4 plan** (only the Step 3 plan above). The canonical Step 4 spec lives in `docs/03-plans/01-phase-2-poc-generator-app.md:210-308`.

## Related Research

No prior research documents found under `thoughts/shared/research/`. This is the first.

## Open Questions

The following items are divergences between Step 4's pseudocode in `docs/03-plans/01-phase-2-poc-generator-app.md` and the schema/code actually on disk. They are recorded here as observations, not recommendations:

1. **`Instruction.user_intent`** — referenced in plan (line 118, line 261) but not present in the Step 2 migration. Needs a decision at Step 4 kickoff: add column, or repurpose `description` / `research_output`.
2. **`Instruction.phase = :processing`** — plan uses this value (line 262) but actual enum is `researching / planning / implementing / completed / failed / cancelled`. Either the enum needs extending or the tool must pick one of the existing values (likely `planning` or `implementing`).
3. **`Revision#prompt`, `started_at`, `finished_at`, `metrics`** — plan assumes these exist (lines 127-131, 267-270, 347, 371-375) but the Step 2 migration omits them. Step 4 creates revisions with `prompt:` (line 269) — this would fail until a migration lands.
4. **`anchor_message: project.chat.messages.last`** in plan pseudocode vs. current fixture wiring (`anchor_message_id` pointing at a specific start_generation message). Both are compatible; just noting the fixture's shape as reference.
5. **Chat system prompt mechanism** — plan's Open Question #4 (line 462) proposes `chat.with_instructions(...)` per-request in `ChatRespondJob` rather than in `Chat.create!`. Not yet implemented; Step 4 is the first place this matters.
6. **Tool instance scoping** — Step 3 plan said tools get `project:` injected at instantiation (`StartGeneration.new(project: project)`), but the main plan's pseudocode uses `Current.project` inside `execute`. These are two different shapes; Step 4 needs to pick one. Step 3's decision supersedes the main plan per the "supersedes the sketch below" note at `docs/03-plans/01-phase-2-poc-generator-app.md:186`.
