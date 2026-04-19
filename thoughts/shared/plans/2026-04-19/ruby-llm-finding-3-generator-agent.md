---
date: 2026-04-19
author: Paweł Strzałkowski
branch: phase-2-step-4-tools-and-create-plan
status: draft
related_research: thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md
skill_refs:
  - .claude/skills/ruby_llm-skill/references/agents.md
  - .claude/skills/ruby_llm-skill/references/rails.md
---

# RubyLLM Finding 3 — Replace hand-rolled chat wiring with `GeneratorAgent`

## Overview

Replace the per-call instruction/tool wiring currently done inside `ChatRespondJob#perform` with a class-level `RubyLLM::Agent`. This is a pure canonicalization refactor: no behavioural or UX change, no touching of streaming/persistence. The only purpose is to align with the shape the `ruby_llm` skill describes in `references/agents.md`.

## Current State Analysis

- `app/jobs/chat_respond_job.rb:4-16` reads `app/prompts/chat_system.md` at load time and, on every `perform`, re-applies `with_instructions(..., replace: true)` plus `with_tools(StartGeneration.new(project:), SuggestPrompts.new(project:), replace: true)` before calling `chat.complete`.
- `app/controllers/projects_controller.rb:16` creates the chat with `project.create_chat!` — a plain AR `has_one` create with no RubyLLM-specific configuration.
- `app/agents/` exists but is empty — created by the `ruby_llm:install` generator, never populated.
- `app/prompts/chat_system.md` holds the system prompt as plain markdown (no interpolation).
- `app/models/chat.rb` already declares `acts_as_chat` and `belongs_to :project` — ready to be referenced via `chat_model Chat` on the agent.

Constraint verified against the skill (`references/agents.md:17`): `RubyLLM::Agent` delegates `.ask`, `.with_tool(s)`, `.with_instructions`, `.on_*`, `.complete`, and streaming to an internal chat — so the existing streaming body (`chat.complete do |chunk| … end`) works unchanged once `chat` is replaced by `agent`.

## Desired End State

- `app/agents/generator_agent.rb` exists and is the single source of truth for model, tools, and instructions used in the chat loop.
- `app/prompts/generator_agent/instructions.txt.erb` is the canonical prompt file, auto-resolved by RubyLLM from the agent's snake-cased class name.
- `ProjectsController#create` creates the chat via `GeneratorAgent.create!(project: project)` — the project association is persisted on the `chats.project_id` column, as before.
- `ChatRespondJob#perform` reduces to: load the user message, call `GeneratorAgent.find(chat_id)`, stream with `agent.complete { … }`. No `CHAT_SYSTEM_PROMPT` constant, no `with_instructions`, no `with_tools`.
- The prompt file at `app/prompts/chat_system.md` is removed.
- `test/jobs/chat_respond_job_test.rb` passes; the two spy-tests (`applies CHAT_SYSTEM_PROMPT…`, `registers …tool`) are rewritten to assert that `Chat#with_instructions` and `Chat#with_tools` are invoked during `GeneratorAgent.find`, carrying the expected prompt and tool instances (spy mechanism itself is unchanged — Agent delegates through to the Chat methods).

Verification:
- `bin/rails test test/jobs/chat_respond_job_test.rb` — green.
- `bin/rails test` — no regressions.
- Manual smoke: create a project in dev, send a message, observe a streamed assistant response that can call `start_generation` / `suggest_prompts` (behaviour identical to pre-refactor).

### Key Discoveries

- Agent config on `.create!`/`.find` — skill `references/agents.md:82-97`. `.find` re-applies instructions as a runtime-only message so no duplicate system row is persisted.
- `chat.project` inside the `tools` block works because the block runs in a runtime context that exposes `chat` and any declared `inputs` (skill `references/agents.md:66`). This lets us avoid declaring `inputs :project`, which would otherwise conflict with the `project:` kwarg that Rails routes to `Chat.create!` (skill `references/agents.md:99`: "kwargs are split — anything declared via `inputs` is an input value; everything else flows into the Rails `create!`/`create` call").
- `acts_as_chat` already gives `Chat` the `.complete`, `.with_instructions`, `.with_tools` methods that the test's monkey-patches/spies target — delegation from Agent lands on the same methods, so existing test scaffolding still works.

## What We're NOT Doing

- **Not switching streaming to `broadcast_append_chunk`.** That's Finding 1, already planned separately in `thoughts/shared/plans/2026-04-19/ruby-llm-finding-1-canonical-streaming.md`. Streaming body inside the job stays byte-for-byte identical.
- **Not moving user-message persistence into the job.** Controllers continue to persist the user row before enqueue. Finding 4 discusses this trade-off; it stays as a deliberate architectural choice.
- **Not touching `chat.complete` vs `chat.ask`.** Keeping `complete` — still correct because the user message is already persisted by the time the job runs.
- **Not restructuring `StartGeneration` / `SuggestPrompts`** — tool classes and their `execute` bodies are untouched.
- **Not addressing Findings 2, 5, 6, 7** — each is a separate plan.
- **Not introducing `inputs :project`** — unnecessary given `chat.project` access, and it would collide with the `project:` kwarg that must flow into `Chat.create!` for the `belongs_to` association.

## Implementation Approach

One atomic commit. The change is small and no meaningful intermediate state leaves the app working (renaming the prompt breaks the job; adding the agent without wiring it up is dead code). Each edit below is required for the next to compile/run.

## Phase 1: Replace hand-rolled chat wiring with `GeneratorAgent`

### Commit
`phase 2 step 4 refinement: extract GeneratorAgent (Finding 3)`

### Overview
Introduce `GeneratorAgent`, move the prompt to the canonical ERB path, and switch the two call sites (`ProjectsController#create`, `ChatRespondJob#perform`) to use the agent. Migrate the job test to assert the new setup path.

### Changes Required

#### 1. Create the agent class

**File**: `app/agents/generator_agent.rb` (new)

```ruby
class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat

  tools do
    [
      StartGeneration.new(project: chat.project),
      SuggestPrompts.new(project: chat.project)
    ]
  end
end
```

Notes:
- `instructions` is intentionally omitted. RubyLLM auto-resolves `app/prompts/generator_agent/instructions.txt.erb` from the snake-cased class name (skill `references/agents.md:57-64`).
- `chat` inside the `tools` block is the runtime-context accessor provided by `RubyLLM::Agent` — same mechanism that powers `instructions { … }` interpolation.
- Model ID is copied from the current `config/initializers/ruby_llm.rb:3` default to keep behaviour identical. Not re-centralized for now.

#### 2. Move the prompt to the canonical path

**From**: `app/prompts/chat_system.md` (delete after move)
**To**: `app/prompts/generator_agent/instructions.txt.erb` (new, same content verbatim — no ERB tags, but `.erb` extension is the convention RubyLLM auto-resolves)

The content is the existing 9-line prompt from `app/prompts/chat_system.md`; no edits.

#### 3. Wire up the controller

**File**: `app/controllers/projects_controller.rb`
**Change**: line 16 — replace `project.create_chat!` with `GeneratorAgent.create!(project: project)`.

```ruby
# Before
project = Project.create!(name: description.truncate(60))
chat = project.create_chat!
first_message = chat.messages.create!(role: :user, content: description)
ChatRespondJob.perform_later(first_message.id)

# After
project = Project.create!(name: description.truncate(60))
chat = GeneratorAgent.create!(project: project)
first_message = chat.messages.create!(role: :user, content: description)
ChatRespondJob.perform_later(first_message.id)
```

The `project:` kwarg flows into `Chat.create!(project: project)` (not declared as an agent input, so it's routed to the Rails create call per skill `references/agents.md:99`). `chats.project_id` ends up persisted exactly as today.

#### 4. Shrink the job

**File**: `app/jobs/chat_respond_job.rb`

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

Removed: `CHAT_SYSTEM_PROMPT` constant, `chat.with_instructions(...)`, `chat.with_tools(...)`. `chat` is still dereferenced from `user_message.chat` for the streaming helpers (broadcasting and `latest_streaming_assistant`) and for the rescue branch — these operate on AR rows, not on the RubyLLM wiring, so they stay.

#### 5. Update the job test

**File**: `test/jobs/chat_respond_job_test.rb`

Two assertions change; everything else stays as-is.

- `test "applies CHAT_SYSTEM_PROMPT via with_instructions on each perform"` → rename to `"applies the GeneratorAgent instructions via with_instructions on each perform"`. Expected argument changes from `ChatRespondJob::CHAT_SYSTEM_PROMPT` to the content of `Rails.root.join("app/prompts/generator_agent/instructions.txt.erb").read` (loaded once at the top of the test, e.g. `AGENT_INSTRUCTIONS = Rails.root.join(...).read`). The spy mechanism (`spy_with_instructions` monkey-patching `Chat#with_instructions`) is unchanged — Agent delegates through to the same method.
- `test "registers a StartGeneration tool bound to the project before completing"` and `"registers a SuggestPrompts tool bound to the project before completing"` — unchanged logic. Agent's `tools` block produces `StartGeneration.new(project: chat.project)` and `SuggestPrompts.new(project: chat.project)` during `.find`, so the existing `spy_with_tools` captures the same instances, and `instance_variable_get(:@project)` still equals `@project`.
- `test "applies CHAT_SYSTEM_PROMPT…"` — the `kwargs[:replace] == true` assertion may or may not hold; Agent.find is documented to apply instructions as a runtime-only message. If `replace: true` is not forwarded, drop that specific assertion and keep only the prompt-content assertion. Decide during execution by reading the captured kwargs.

Fixture setup change: the test's `setup` block does `@chat = @project.create_chat!` — update to `@chat = GeneratorAgent.create!(project: @project)` so the test's chat is configured identically to production.

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/jobs/chat_respond_job_test.rb` — all tests pass
- [x] `bin/rails test` — full suite passes, no regressions
- [x] `bin/rubocop` — no new offenses (if project uses it; skip if not configured)
- [x] `app/agents/generator_agent.rb` exists and contains `class GeneratorAgent < RubyLLM::Agent`
- [x] `app/prompts/generator_agent/instructions.txt.erb` exists
- [x] `app/prompts/chat_system.md` is deleted
- [x] `grep -r "CHAT_SYSTEM_PROMPT" app/ test/` returns no matches
- [x] `grep -r "with_instructions\|with_tools" app/jobs/` returns no matches

#### Manual Verification
- [ ] Create a new project in dev (`bin/dev`), type a build request. A streamed assistant reply appears in the UI, identical in look/feel to pre-refactor.
- [ ] The assistant calls `start_generation` when the user's intent is clear — verify via `rails c`: `Project.last.instructions.any?` and an `Instruction` row was created with revisions.
- [ ] The assistant calls `suggest_prompts` after `start_generation` — verify the suggestions frame appears in the UI.
- [ ] Continue the conversation with a second user message; the agent re-uses the same chat (no duplicate system row — check `Project.last.chat.messages.where(role: :system).count == 1`, or `== 0` if RubyLLM routes instructions as runtime-only on `.find`).
- [ ] Kill the process mid-stream (or raise in a stub) and confirm the error path still writes `"Error: …"` to the assistant row and broadcasts it.

**Implementation Note**: After all automated verification passes, pause for manual confirmation before the commit lands.

---

## Testing Strategy

### Unit-level
Existing `ChatRespondJobTest` covers:
- happy path (single / multi chunk)
- broadcast count per chunk
- empty-chunk filtering
- mid-stream and pre-stream error handling
- instruction + tool wiring (being rewritten)

No new tests required for this refactor — it's a pure replacement. The agent class itself is thin (DSL declarations, no custom methods), so a dedicated `GeneratorAgentTest` would only re-test RubyLLM internals. Skip.

### Manual / integration
Covered by the Manual Verification checklist above. The golden paths are: (1) first message from `ProjectsController#create` → streamed reply → tool call → `Instruction` created; (2) follow-up message from `MessagesController#create` → streamed reply using the same persisted chat.

## Migration Notes

No data migration. `chats` table schema is unchanged. Existing chat rows (if any in dev) continue to work — `GeneratorAgent.find(id)` just loads an AR `Chat` row and applies config; doesn't demand any marker column.

## Rollback

Single-commit refactor: `git revert <sha>` restores the pre-refactor state. No schema changes, no data migration, no external side effects.

## References

- Research: `thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` — Finding 3 at lines 217-275
- Skill: `.claude/skills/ruby_llm-skill/references/agents.md` — `RubyLLM::Agent` DSL, `chat_model`, ERB prompt auto-resolution, input/kwarg split
- Skill: `.claude/skills/ruby_llm-skill/references/rails.md:168-175` — `with_runtime_instructions` behaviour that Agent.find uses under the hood
- Related plan (separate scope): `thoughts/shared/plans/2026-04-19/ruby-llm-finding-1-canonical-streaming.md`
- Current code: `app/jobs/chat_respond_job.rb:1-50`, `app/controllers/projects_controller.rb:16`, `app/prompts/chat_system.md`, `app/models/chat.rb`, `app/tools/start_generation.rb`, `app/tools/suggest_prompts.rb`
