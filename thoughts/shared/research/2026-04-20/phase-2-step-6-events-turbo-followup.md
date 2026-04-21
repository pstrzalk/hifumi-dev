---
date: 2026-04-20T11:06:22+02:00
researcher: Paweł Strzałkowski
git_commit: 7892b69454752ed643faae8b3e28db126971d732
branch: main
repository: rails-app-generator
topic: "Phase 2 Step 6 — Events + Turbo Streams + ChatFollowUpJob: knowledge needed"
tags: [research, phase-2, step-6, event-bus, turbo-streams, ruby-llm, chat-follow-up]
status: complete
last_updated: 2026-04-20
last_updated_by: Paweł Strzałkowski
---

# Research: Phase 2 Step 6 — Events + Turbo Streams + ChatFollowUpJob

**Date**: 2026-04-20T11:06:22+02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: 7892b69454752ed643faae8b3e28db126971d732
**Branch**: main
**Repository**: rails-app-generator

## Research Question

Gather knowledge needed to implement Phase 2 Step 6 of the generator app (events + Turbo Streams + `ChatFollowUpJob`). Capture open questions for later discussion rather than jumping to implementation.

Step 6 will add:
- Subscribers in `config/initializers/event_subscribers.rb` for `revision.{started,completed,failed}` (→ Turbo Stream replace of `revision_<id>`) and `instruction.{completed,failed}` (→ `ChatFollowUpJob`).
- `ChatFollowUpJob` that asks the LLM to summarize/explain and call `SuggestPrompts` after generation ends.
- `app/views/revisions/_revision.html.erb` partial (status badge + git SHA).
- Active-revisions list on `app/views/projects/show.html.erb`.

## Summary

Steps 1–5 have already stood up everything Step 6 depends on: **events are emitted, broadcast conventions are set, `GeneratorAgent` encapsulates the RubyLLM config, and `event_subscribers.rb` reserves the Step 6 slots in a header comment.** Step 6 is almost entirely wiring.

What remains unsettled falls into three buckets:

1. **How the follow-up prompt enters the chat.** The plan snippet (`chat.ask(prompt, tools: [...])`) predates the `GeneratorAgent` refactor (`d485c8c`) and would persist a visible "user" message with internal prompt text. There is no established pattern for system-triggered LLM turns that don't create a user-visible message.
2. **How newly-created revisions first appear in the UI.** `revision.started` broadcasts a *replace* — but there is no `revision_<id>` element on the page until one exists. No append path is defined anywhere.
3. **Several smaller definitions**: what counts as an "active" revision, whether `ChatFollowUpJob` should also fire on `instruction.failed`, whether the revision partial uses a turbo-frame or a plain div, and whether the chat should know about previously-generated revisions as system context.

Everything else (event names, payloads, stream identity, partial-path explicitness, queue assignment, ToolCall touch workaround, Solid Cable in dev) is already pinned by prior steps and confirmed by live code.

## Detailed Findings

### 1. Event contracts are frozen (Step 5)

All events and payloads that Step 6 will react to are already emitted. Source: `app/jobs/execute_instruction_job.rb` and `app/tools/start_generation.rb`.

| Event | Emitted at | Payload | Currently subscribed? |
|-------|------------|---------|----------------------|
| `instruction.requested` | `app/tools/start_generation.rb:48-51` | `{ instruction_id: }` | **Yes** — `ExecuteInstructionJob.perform_later` |
| `revision.started` | `app/jobs/execute_instruction_job.rb:77` | `{ revision_id: }` | No |
| `revision.completed` | `app/jobs/execute_instruction_job.rb:107-111` | `{ revision_id:, git_sha: }` | No |
| `revision.failed` | `app/jobs/execute_instruction_job.rb:114-118` | `{ revision_id:, error: "exit #{code}" }` | No |
| `instruction.completed` | `app/jobs/execute_instruction_job.rb:22-25` | `{ instruction_id: }` | No |
| `instruction.failed` | `app/jobs/execute_instruction_job.rb:22-25` | `{ instruction_id: }` | No |

The event is named `instruction.#{final_phase}` at the emission site, where `final_phase = instruction.revisions.reload.all?(&:completed?) ? :completed : :failed`.

Test helpers already exist for capturing events: see `test/tools/start_generation_test.rb:62-77` (inline subscribe/unsubscribe) and `test/jobs/execute_instruction_job_test.rb:256-267` (`capture_events(*names) { ... }` helper).

### 2. `config/initializers/event_subscribers.rb` — extend in place

File exists, Step 5 shipped it. Current content (13 lines):

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

The header comment already commits to what Step 6 will add. Pattern is block-based `ActiveSupport::Notifications.subscribe(event_name) do |*, payload| ... end`. No helper class.

**Constraint, reiterated by the comment**: subscribers only enqueue jobs or broadcast Turbo Streams — no business logic.

### 3. Turbo Stream broadcasting — two coexisting patterns

**Pattern A — AR callback broadcast** (used by `Message`):

```ruby
# app/models/message.rb:5-29
after_create_commit :broadcast_append_message
after_update_commit :broadcast_replace_message

def broadcast_append_message
  return unless %w[user assistant].include?(role)
  broadcast_append_later_to chat.project,
    target: "messages",
    partial: "messages/message",
    locals: { message: self }
end

def broadcast_replace_message
  broadcast_replace_later_to chat.project,
    target: ActionView::RecordIdentifier.dom_id(self),
    partial: "messages/message",
    locals: { message: self }
end
```

**Pattern B — direct broadcast via event subscriber / service / job** (used by `SuggestPrompts` and `ChatRespondJob`):

```ruby
# app/tools/suggest_prompts.rb:24-30
Turbo::StreamsChannel.broadcast_replace_to(
  @project,
  target: "suggestions",
  partial: "suggestions/frame",
  locals: { prompts: prompts }
)
```

**Stream identity**: all chat-lane broadcasts target the `Project` record (`chat.project` or `@project`). View subscribes via `<%= turbo_stream_from @project %>` at `app/views/projects/show.html.erb:2`.

**Explicit `partial:` is mandatory**: `Message` uses `acts_as_message`, which overrides `to_partial_path` per role. The `partial: "messages/message"` key has to be set by every broadcast call or the wrong path resolves. (Captured in memory `project_ruby_llm_partial_path.md` — the live code honors it on every broadcast site.)

**Cable config**: `config/cable.yml` uses `solid_cable` in both `development` and `production` (memory `project_dev_cable_solid.md`). Test uses `test` adapter. This is a prerequisite for cross-process broadcasts from the `:generation` queue worker to reach the browser.

Full broadcast inventory (locations, triggers, targets, partials): see the "All Broadcasts" table at the end of this section.

#### All broadcasts currently in the codebase

| Location | Trigger | Stream | Target | Partial | Condition |
|----------|---------|--------|--------|---------|-----------|
| `app/models/message.rb:5` (via `:broadcast_append_message`) | `after_create_commit` | `chat.project` | `"messages"` | `"messages/message"` | role in `[user, assistant]` |
| `app/models/message.rb:6` (via `:broadcast_replace_message`) | `after_update_commit` | `chat.project` | `dom_id(self)` | `"messages/message"` | always |
| `app/models/tool_call.rb:8` | `after_commit :touch_message` | — (re-triggers Message replace) | — | — | always |
| `app/jobs/chat_respond_job.rb:18` | streaming chunk loop | `project` | `dom_id(message)` | `"messages/message"` | while streaming |
| `app/jobs/chat_respond_job.rb:25` | rescue path | `project` | `dom_id(message)` | `"messages/message"` | on error |
| `app/tools/suggest_prompts.rb:18` | tool `execute` | `@project` | `"suggestions"` | `"suggestions/frame"` | tool invoked |
| `app/controllers/messages_controller.rb:18` | form submit success | — (direct turbo-stream response) | `dom_id(@project, :message_form)` | `"messages/form"` | after create |
| `app/controllers/messages_controller.rb:8` | blank content | — (direct turbo-stream response, 422) | `dom_id(@project, :message_form)` | `"messages/form"` | validation fail |

### 4. `ChatRespondJob` — the pattern to mirror in `ChatFollowUpJob`

`app/jobs/chat_respond_job.rb` (42 lines, entire file):

```ruby
class ChatRespondJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    user_message = Message.find(message_id)
    agent = GeneratorAgent.find(user_message.chat_id)
    chat = user_message.chat
    project = chat.project

    agent.complete do |chunk|
      delta = chunk.content.to_s
      next if delta.empty?

      assistant = latest_streaming_assistant(chat)
      next if assistant.nil?

      assistant.update_columns(content: assistant.content.to_s + delta)
      broadcast_replace(project, assistant)
    end
  rescue StandardError => e
    # TODO(Step 6): typed error event + proper UX
    Rails.logger.error(e.full_message)
    target = latest_streaming_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
    target.update!(content: "Error: #{e.message}")
    broadcast_replace(project, target)
  end

  private

  def latest_streaming_assistant(chat)
    chat.messages.where(role: :assistant).order(:id).last
  end

  def broadcast_replace(project, message)
    Turbo::StreamsChannel.broadcast_replace_to(
      project,
      target: ActionView::RecordIdentifier.dom_id(message),
      partial: "messages/message",
      locals: { message: message }
    )
  end
end
```

Key observations:

- Uses `GeneratorAgent.find(chat_id)` — NOT `Chat#find` + manual `with_tool/with_instructions`. Model, tools, and system prompt come pre-bound from `GeneratorAgent`.
- Calls `agent.complete { |chunk| ... }` — `complete`, not `ask`, because the triggering user message is already persisted (memory `project_ruby_llm_complete_vs_ask.md`).
- `update_columns` bypasses validations and — critically — the `after_update_commit` broadcast on `Message`. During streaming, the job owns broadcasting to avoid double replaces.
- `queue_as :default` — **NOT** `:generation`. `:default` has concurrency 3×`JOB_CONCURRENCY`; `:generation` has concurrency 1 and is reserved for `ExecuteInstructionJob`. `ChatFollowUpJob` must also sit on `:default`.
- The rescue path creates a fresh assistant message if no streaming message exists yet. Calling `chat.messages.create!` fires `after_create_commit :broadcast_append_message`, which appends the error row. Then `update!` + manual `broadcast_replace` updates it. Two broadcasts for one error is fine.
- Line 21 comment `# TODO(Step 6): typed error event + proper UX` — Step 6's error handling is supposed to emit a typed event and render something better than "Error: …" inline.

### 5. `GeneratorAgent` — the RubyLLM configuration object

`app/agents/generator_agent.rb`:

```ruby
class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  instructions

  tools do
    [
      StartGeneration.new(project: chat.project),
      SuggestPrompts.new(project: chat.project)
    ]
  end
end
```

- `model "anthropic/claude-haiku-4.5"` — pinned to the OpenRouter Haiku 4.5 endpoint. Same model used in `CreatePlan::AdHocLLM` (`app/services/create_plan/ad_hoc_llm.rb:4`).
- `chat_model Chat` — backs the agent with the `Chat < ApplicationRecord` model (which has `acts_as_chat`).
- `instructions` with no arguments auto-loads `app/prompts/generator_agent/instructions.txt.erb` (9 lines of Markdown, instructs the LLM to summarize then call `suggest_prompts`).
- `tools do ... end` — evaluated per `GeneratorAgent.find` call. The `chat` variable is the loaded Chat record. Both tools receive `project: chat.project` at instantiation and store it in `@project`.

**Consequence for `ChatFollowUpJob`**: `GeneratorAgent.find(chat_id).complete { ... }` already supplies model, both tools, and the system prompt. The plan snippet (`chat.ask(prompt, tools: [StartGeneration, SuggestPrompts])` at `docs/03-plans/01-phase-2-poc-generator-app.md:425`) predates this refactor (commit `d485c8c phase 2 step 4 refinement: extract GeneratorAgent (Finding 3)`) and is stale.

### 6. `Chat`, `Message`, `ToolCall` — acts_as + broadcast wiring

`app/models/chat.rb` (5 lines):
```ruby
class Chat < ApplicationRecord
  acts_as_chat
  belongs_to :project
end
```
No `on_new_message` / `on_end_message` overrides. RubyLLM's defaults handle message lifecycle (it auto-creates the assistant message row before the API request fires).

`app/models/message.rb` relevant bits:
- `acts_as_message`
- `after_create_commit :broadcast_append_message` / `after_update_commit :broadcast_replace_message` (details in §3)
- `visible_in_chat?` at lines 8-11:
  ```ruby
  def visible_in_chat?
    return true if role == "user"
    role == "assistant" && (content.to_s.strip.present? || tool_calls.any?)
  end
  ```
  User messages are always visible. Assistant messages are visible when they have content or tool calls. Tool role messages are always hidden.

`app/models/tool_call.rb:8-14`:
```ruby
after_commit :touch_message

def touch_message
  message&.touch
end
```
RubyLLM attaches `tool_calls` AFTER `message.save!`, so the Message's first `after_update_commit` broadcasts before tool_calls exist and the pill doesn't render. `touch_message` forces a second update, which re-broadcasts with tool_calls now visible (memory `project_ruby_llm_message_lifecycle.md`). This pipeline already supports `ChatFollowUpJob`'s LLM calling `SuggestPrompts` — nothing new needed.

### 7. `Revision` and `Instruction` — model shape (unchanged)

**`app/models/revision.rb`** (17 lines):

```ruby
class Revision < ApplicationRecord
  belongs_to :project
  belongs_to :instruction
  belongs_to :parent, class_name: "Revision", optional: true

  enum :status, {
    pending: "pending",
    generating: "generating",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :position, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :summary, presence: true
  validates :prompt, presence: true
end
```

- Auto-generated predicates: `pending?`, `generating?`, `completed?`, `failed?`.
- No broadcasts, no after-commit hooks.
- Schema (db/schema.rb lines 112-130): `status`, `position`, `summary`, `prompt`, `git_sha`, `started_at`, `finished_at`, `metrics` (JSON). Unique index on `[instruction_id, position]`.
- `metrics` shape on completion (`app/jobs/execute_instruction_job.rb`): `{ wall_seconds:, exit_code:, git_sha: }`. Top-level `git_sha` column is *also* set, so the partial can read `revision.git_sha` directly.

**`app/models/instruction.rb`** (16 lines):

```ruby
class Instruction < ApplicationRecord
  belongs_to :project
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions, dependent: :destroy

  enum :phase, {
    researching: "researching",
    planning: "planning",
    implementing: "implementing",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  validates :description, presence: true
end
```

- Auto-generated predicates for all six phases.
- **No `processing` phase** — the plan section on Step 6 (`docs/03-plans/01-phase-2-poc-generator-app.md:429`) uses the word "processing" informally. Non-terminal phases in code are `researching`, `planning`, `implementing`.
- Final phase is set in `ExecuteInstructionJob#perform` lines 20-21: `final_phase = instruction.revisions.reload.all?(&:completed?) ? :completed : :failed`.

### 8. `app/views/projects/show.html.erb` — current layout

17 lines:

```erb
<section class="w-full max-w-3xl mx-auto">
  <%= turbo_stream_from @project %>

  <h1 class="text-2xl font-semibold mb-4"><%= @project.name %></h1>

  <div id="messages" class="flex flex-col gap-3 mb-6">
    <%= render partial: "messages/message", collection: @messages, as: :message %>
  </div>

  <%= render "suggestions/frame", prompts: [] %>

  <% if flash[:alert] %>
    <div class="mb-4 text-red-700"><%= flash[:alert] %></div>
  <% end %>

  <%= render "messages/form", project: @project %>
</section>
```

Controller (`app/controllers/projects_controller.rb:24-27`): `@messages = @project.chat.messages.order(:created_at)`.

No `@revisions`, no revisions frame/container, no `app/views/revisions/` directory. Step 6 inserts the revisions list — the plan says above the chat.

### 9. Queue + retry configuration

`config/queue.yml`:
- `:generation` queue — threads 1, processes 1 (single concurrent generation, by design).
- `:default` + `:mailers` — threads 3, processes `ENV("JOB_CONCURRENCY", 1)`.

`app/jobs/application_job.rb` — `retry_on` and `discard_on` both commented out. No inherited retry logic. `ChatRespondJob` has no retry/discard declarations either.

`ChatFollowUpJob` fits on `:default` with the same implicit defaults.

### 10. `bin/execute-instruction` — the existing debug entry point

`bin/execute-instruction` (13 lines): loads Rails env, takes `ARGV[0]` as instruction id, calls `ExecuteInstructionJob.perform_now(id)`. Events fire normally via `ActiveSupport::Notifications.instrument`. Useful for Step 6 tests: a subscriber attached in the test harness observes the 5-event sequence emitted by a full run.

### 11. CreatePlan + StartGeneration lifecycle (relevant to follow-up)

`app/tools/start_generation.rb` (67 lines):
- `initialize(project:)` stores `@project`.
- `execute(intent:, clarifications: {})` → calls `CreatePlan.call(...)`, wraps instruction + revisions creation in a transaction, emits `instruction.requested`, returns `{ instruction_id:, revision_count:, instruction_description: }`.
- Rescues `CreatePlan::AdHocLLM::InvalidResponse` and returns `{ error: "Could not generate a plan: …" }`.
- Sets `phase: :implementing` on the Instruction (not `:researching` — research phase is deferred beyond Phase 2).
- `anchor_message` is the latest user message (`project.chat.messages.where(role: :user).order(:id).last`).

`app/services/create_plan/ad_hoc_llm.rb`:
- System prompt at `app/prompts/create_plan_system.md` (frozen on load).
- `RubyLLM.chat(model: "anthropic/claude-haiku-4.5").with_instructions(system).with_schema(PlanSchema).ask(user)` → returns `CreatePlan::Result { instruction_description:, revisions: [{ summary:, prompt: }, …] }`.
- Uses `ask` here (not `complete`) because no Rails-backed user message is being persisted — it's an ad-hoc single-shot call.

### 12. Prompt instructions — what the LLM already knows

`app/prompts/generator_agent/instructions.txt.erb` tells the LLM:

> After `start_generation` returns, summarise what you started in 1-2 sentences, and then call the `suggest_prompts` tool with 3-5 natural next steps...

So the LLM is already primed to call `SuggestPrompts` after a tool return. `ChatFollowUpJob`'s prompt just has to invite the LLM into this mode again — it does not need to spell out "call SuggestPrompts".

### 13. Plan contract for Step 6 — load-bearing quotes

From `docs/03-plans/01-phase-2-poc-generator-app.md`:

- DoD item 6 (line 39): "Revision status (generating/completed/failed) flows through Turbo Stream to the chat UI."
- DoD item 7 (line 40): "After `instruction.completed`, a subscriber enqueues `ChatFollowUpJob` → LLM invokes `SuggestPrompts` → user sees cards with proposals."
- Step 6 sketch (lines 394-430) is plain pseudocode, predates `GeneratorAgent`, and uses `chat.ask(prompt, tools: [...])` — which diverges from the current `GeneratorAgent.find(chat_id).complete { }` pattern.
- Open question #4 (line 464): "Does the RubyLLM chat receive context about `Project.revisions`?" — plan answers "yes, via `chat.with_instructions(...)` set in `ChatRespondJob` each time to refresh state". Current `ChatRespondJob` does NOT do this — it relies on the static agent `instructions`. So the answer in the plan is not yet reflected in code.

## Code References

- `app/jobs/execute_instruction_job.rb:22-25` — emits `instruction.completed` / `instruction.failed`
- `app/jobs/execute_instruction_job.rb:77` — emits `revision.started`
- `app/jobs/execute_instruction_job.rb:107-111` — emits `revision.completed` with `git_sha`
- `app/jobs/execute_instruction_job.rb:114-118` — emits `revision.failed` with `error`
- `app/tools/start_generation.rb:48-51` — emits `instruction.requested`
- `config/initializers/event_subscribers.rb:11-13` — current sole subscriber
- `app/jobs/chat_respond_job.rb:1-42` — streaming + broadcast pattern to mirror
- `app/jobs/chat_respond_job.rb:21` — `TODO(Step 6): typed error event + proper UX`
- `app/agents/generator_agent.rb:1-12` — agent config (model, tools, instructions)
- `app/models/chat.rb:1-5` — `acts_as_chat`, no overrides
- `app/models/message.rb:5-29` — callback-based broadcast wiring
- `app/models/message.rb:8-11` — `visible_in_chat?`
- `app/models/tool_call.rb:8-14` — touch workaround for tool_call broadcast timing
- `app/models/revision.rb:6-11` — status enum values
- `app/models/instruction.rb:6-13` — phase enum values (no `processing`)
- `app/models/project.rb:8-14` — `workspace_path`, `workspace_initialized?`
- `app/tools/suggest_prompts.rb:16-31` — direct broadcast-replace target `"suggestions"`
- `app/views/projects/show.html.erb:1-17` — subscribes to `@project` stream, has `#messages` container only
- `app/views/messages/_message.html.erb:1-13` — `dom_id(message)` wrapper + pill branch
- `app/helpers/messages_helper.rb:7-18` — `render_as_pill?`, `tool_call_pill_text`
- `app/services/create_plan/ad_hoc_llm.rb:3-18` — ad-hoc LLM usage pattern (`ask` + `with_schema`)
- `config/cable.yml` — solid_cable in dev + prod
- `config/queue.yml` — `:generation` concurrency=1; `:default` threads=3
- `db/schema.rb:112-130` — revisions table (has `started_at`, `finished_at`, `git_sha`, `metrics`)
- `test/jobs/execute_instruction_job_test.rb:256-267` — `capture_events` helper
- `test/tools/start_generation_test.rb:62-77` — inline event-capture idiom

## Architecture Documentation

- **Single event-bus choke point.** `config/initializers/event_subscribers.rb` is the only place where `ActiveSupport::Notifications` subscribers live; the file's header comment enforces "no business logic — only enqueue or broadcast". Step 6 extends this file without creating a parallel abstraction.
- **`GeneratorAgent` is the canonical RubyLLM entry point for chat turns.** Code outside `CreatePlan::AdHocLLM` that talks to the chat LLM goes through `GeneratorAgent.find(chat_id).complete { … }`. Tools, model, and system prompt are declared once on the agent class.
- **Broadcasting splits by trigger source.** User-initiated model changes broadcast from AR callbacks (`Message`). System-initiated status changes driven by job events (Revision, future Instruction status UI) are expected to broadcast from event subscribers — the Step 5 plan and the layer-integration doc both state this (see Historical Context). That keeps trigger source readable.
- **Every `broadcast_*` passes `partial:` explicitly.** Because RubyLLM's `acts_as_message` overrides `to_partial_path` per role, implicit partial resolution silently renders the wrong file. Other models inherit the same convention by habit.
- **Cross-process broadcasting requires Solid Cable in dev.** `ExecuteInstructionJob` runs in the `:generation` Solid Queue worker process. Broadcasts from that process reach the web process's WebSocket only because dev `cable.yml` uses `solid_cable` (not `async`).
- **Streaming inside a block bypasses normal callbacks.** `ChatRespondJob` uses `update_columns` intentionally so `Message#after_update_commit` does not double-broadcast during streaming. If `ChatFollowUpJob` streams, it must do the same.

## Historical Context (from thoughts/)

- `./thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md` — established `chat.complete` over `chat.ask` for pre-persisted user messages; introduced the `update_columns` + manual broadcast pattern during streaming.
- `./thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md` — tools take `project:` in `initialize`; the chat system prompt instructs "summarize + call `suggest_prompts` after a tool returns"; `Current.project` idea was rejected in favor of constructor injection.
- `./thoughts/shared/plans/2026-04-19/phase-2-step-4-refinement-plan-schema.md` — `PlanSchema` + `with_schema` replace the earlier `emit_plan` tool for `CreatePlan::AdHocLLM`.
- `./thoughts/shared/plans/2026-04-19/ruby-llm-finding-3-generator-agent.md` — introduces the `GeneratorAgent` abstraction; commits to `tools do ... end` with `chat.project` access at runtime. This is what makes the plan's `chat.ask(prompt, tools: [...])` snippet stale.
- `./thoughts/shared/plans/2026-04-20/phase-2-step-5-execute-instruction-job.md` — freezes event contracts and decides broadcasts for Revision/Instruction live in event subscribers, not AR callbacks.
- `./thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` — Finding 1 (streaming loop is non-canonical but accepted for Phase 2); Finding 5 (`ToolCall#touch_message` works around RubyLLM's save-order for tool_calls).
- `./thoughts/shared/research/2026-04-20/phase-2-step-5-execute-instruction-job.md` — codebase state as of Step 5 close; enumerates the six events emitted; test patterns for event capture.

Memories reinforcing the above (from `.claude/projects/.../memory/`): `project_ruby_llm_complete_vs_ask.md`, `project_ruby_llm_partial_path.md`, `project_ruby_llm_chat_api.md`, `project_ruby_llm_message_lifecycle.md`, `project_dev_cable_solid.md`, `project_form_replace_over_redirect.md`.

## Related Research

- `./thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md`
- `./thoughts/shared/research/2026-04-20/phase-2-step-5-execute-instruction-job.md`

## Open Questions

Held for discussion before Step 6 implementation begins.

### Q1. How does the `ChatFollowUpJob` prompt enter the chat?

The plan snippet says `chat.ask("Generation completed. Suggest 3-5 natural next steps (SuggestPrompts tool).")`. `Chat#ask` persists that string as a `role: :user` message, and `Message#visible_in_chat?` returns `true` for every user message — it would appear in the UI as the user "saying" an internal prompt. There is no established pattern in this codebase for a system-triggered LLM turn that does not create a visible user message.

Sub-questions:
- Does RubyLLM `acts_as_message` support a `role: :system` or `role: :developer` that survives persistence and participates in the next `complete`?
- Does `Chat#complete` drive the LLM without a pending user message (i.e. can it run against the existing history alone)?
- If we keep a user-row approach: is the right carve `visible_in_chat?` checking a `system_triggered` boolean column, or a `role` value outside `[user, assistant, tool]`?
- Alternative: persist the follow-up as a user message whose content is *user-facing* (e.g. "Build finished ✅") so it is acceptable to show, and let the LLM read that as the prompt?

Whatever we pick has to work with `GeneratorAgent.find(chat_id).complete { }`, not the stale `chat.ask(prompt, tools: [...])` signature.

### Q2. How do newly-created `Revision` records first appear in the UI?

`turbo_stream_from @project` is on the page. The user is on `/projects/:id` when `StartGeneration` runs in `ChatRespondJob`; Revisions are created; `ExecuteInstructionJob` runs; it emits `revision.started` and the Step 6 subscriber tries to `broadcast_replace_to(project, target: "revision_<id>", ...)`. But the page was rendered before any revisions existed, so there is no `revision_<id>` element to replace — the broadcast is a no-op and the user sees nothing until they reload.

Options to discuss:
- (a) Add `after_create_commit :broadcast_append_revision` on `Revision` (copy of the `Message` pattern). Breaks "broadcasts live in event subscriber" convention.
- (b) Subscribe to `instruction.requested` and broadcast-replace a whole "revisions list" container. Conventional; means rendering the full list partial server-side.
- (c) Emit a new event (`revision.created`, or include revision ids in `instruction.requested`) and subscribe-append in the subscriber.
- (d) Broadcast-append directly from `StartGeneration#execute` (same shape as `SuggestPrompts` broadcasting from a tool).

DoD item 6 says "live progress" — reload-to-see is not acceptable. Pick one.

### Q3. What counts as an "active" revision for the list above the chat?

Plan wording (`docs/03-plans/01-phase-2-poc-generator-app.md:429`) uses "Instruction.processing", but the Instruction phase enum has no `processing`. Candidate readings:

- (a) Revisions belonging to Instructions in any non-terminal phase (`researching | planning | implementing`).
- (b) Revisions from the most recent Instruction only (matches `:generation` queue concurrency = 1 — there is never more than one running Instruction at a time).
- (c) All Revisions in `pending | generating | failed` status, regardless of Instruction phase.
- (d) Always show every Revision ever (no "active" filter; UI is the project's full history).

This affects the controller query and the partial's empty state.

### Q4. Does `ChatFollowUpJob` run on `instruction.failed` too?

The plan explicitly says both (`ChatFollowUpJob.perform_later(instruction_id, event: :completed)` and `… event: :failed`). But:
- On failure we may not want to spam the chat with suggestions; the user may be mid-debug.
- On failure, invoking `SuggestPrompts` seems odd — we'd rather invoke a hypothetical "ExplainFailure" tool.
- Or: fire the job for both, and let the branch in the prompt decide what the LLM does.

Confirm: both, only-completed, or both-with-different-prompts?

### Q5. `turbo-frame` or plain `div` for the revision partial?

Plan (line 428) says `<turbo-frame id="revision_<%= revision.id %>">`. The `_message.html.erb` precedent uses a plain `<div id="<%= dom_id(message) %>">`. Both support `broadcast_replace_to`. Turbo-frame adds frame-scoped navigation that we don't need for revisions. Confirm: plain div to match `Message`, or turbo-frame as the plan says?

### Q6. Does the chat need context about existing Revisions in the system prompt?

Plan's open question #4 answered "yes, via `chat.with_instructions(...)` refreshed each turn". Current code doesn't do this. For Step 6's follow-up specifically: the LLM may need to know *what was just built* to write a sensible summary — otherwise it just echoes "Your app is ready, here are some ideas" without specifics.

Options:
- (a) `ChatFollowUpJob` injects a runtime `with_instructions(recent_revisions_summary)` on top of the static agent instructions.
- (b) `ChatFollowUpJob`'s user-role prompt embeds the revision summaries directly.
- (c) Defer — let the LLM's response be generic for Phase 2 and revisit after we see real output.

### Q7. Idempotency and retry behavior for `ChatFollowUpJob`.

If the job fails (rate limit, transient network), Solid Queue retries by default. A retry could:
- Re-invoke the LLM, producing a second follow-up message (duplicates).
- Or skip if a follow-up message already exists for that instruction.

Decide: idempotency check at job entry (skip if `instruction.follow_up_message_id` already set), or accept duplicates as a Phase-2 tradeoff?

### Q8. Error UX when `ChatRespondJob` rescues.

`chat_respond_job.rb:21` has `TODO(Step 6): typed error event + proper UX`. Is Step 6 the right place to address this, or out-of-scope? If in-scope, what does "typed error event" look like (new event name + subscriber, or a structured Message column)?

### Q9. `revision.started` broadcast — does it also reset the `metrics` or `git_sha` columns?

On a `revision.started`, the only DB change is `status: :generating, started_at: Time.current`. Earlier `git_sha`/`metrics` from a previous run (if this is a remediation / re-run scenario — not in Phase 2, but fixtures can have any state) remain. Does the partial need to defensively nil them out on started, or is it sufficient to branch on status? (Probably sufficient, but worth stating.)

### Q10. When does the revisions list disappear?

After `instruction.completed`, are all revisions still shown (now with "completed" badges) or does the list collapse? Plan doesn't say. Relates to Q3 directly.
