---
date: 2026-04-21
author: Paweł Strzałkowski
status: ready
phase: Phase 2 Step 6
depends_on: phase-2-step-5-execute-instruction-job
research: ../research/2026-04-20/phase-2-step-6-events-turbo-followup.md
---

# Phase 2 Step 6 — Events + Turbo Streams + Revision UI

## Overview

Wire the event bus to Turbo Streams so generation progress shows up live in the chat UI. A running instruction's revision cards appear between the page title and the chat, update as each revision transitions through `pending → generating → completed|failed`, then the list clears and a deterministic `role: :assistant` status line lands in the chat ("✅ Generation finished." or "❌ Revision 'X' failed."). Also add a concurrency guard so the LLM can't enqueue a second generation while one is running.

**No LLM follow-up turn.** The plan's original `ChatFollowUpJob` is dropped — the status line is deterministic assistant-voice content, `SuggestPrompts` keeps the pre-generation cards it already broadcast during `StartGeneration`, and any future personalized post-generation summary is left for later.

## Current State Analysis

Steps 1–5 have shipped everything Step 6 depends on:

- **Events fire** from `app/jobs/execute_instruction_job.rb` and `app/tools/start_generation.rb` (`instruction.requested`, `revision.started`, `revision.completed`, `revision.failed`, `instruction.completed`, `instruction.failed`).
- **`config/initializers/event_subscribers.rb`** routes `instruction.requested → ExecuteInstructionJob.perform_later`. Header comment already reserves Step 6's slots.
- **`GeneratorAgent`** is the canonical RubyLLM entry point; `ChatRespondJob` mirrors its streaming pattern.
- **`turbo_stream_from @project`** is on `app/views/projects/show.html.erb:2`. All chat-lane broadcasts target `@project`.
- **Solid Cable** runs in dev + prod (`config/cable.yml`), so broadcasts from the `:generation` worker process reach the web process's WebSocket.
- **Test infrastructure** — `ActionCable::TestHelper` + `assert_broadcasts(stream_name, count)` works in-process (see `test/jobs/chat_respond_job_test.rb:30-38`). Event capture via inline subscribe/unsubscribe (see `test/tools/start_generation_test.rb:62-77`).

**What's missing** — entirely wiring:

- No `app/views/revisions/` directory, no revision partial.
- No revisions container on `projects/show.html.erb`; controller doesn't fetch revisions.
- No subscribers for `revision.*` or `instruction.{completed,failed}`.
- `StartGeneration#execute` does not guard against a second concurrent generation; a user chatting mid-generation could trigger a second `StartGeneration` tool call, which would silently queue behind the first on `:generation` (concurrency=1).
- `app/jobs/chat_respond_job.rb:21` carries `# TODO(Step 6): typed error event + proper UX` — this is out of scope for Step 6 (see "What We're NOT Doing") but the marker needs to be renamed to stop signaling intent.

## Desired End State

A user on `/projects/:id` who types a build request experiences:

1. (already works) LLM replies, asks clarifying questions if needed, eventually calls `start_generation`.
2. (this step) The moment `instruction.requested` fires, a revisions list appears between the project title and the chat with N cards, all `⏸ pending`.
3. (this step) As `ExecuteInstructionJob` iterates, each card transitions `pending → ⏳ generating → ✅ completed` (with git SHA) or `❌ failed`.
4. (this step) When `instruction.completed` / `instruction.failed` fires: the list clears, and a new `role: :assistant` message lands in the chat (`"✅ Generation finished."` or `"❌ Revision 'X' failed."`).
5. (this step) If the user types another "please add X" while a generation is in progress, the LLM either refuses ahead of the tool call (prompt guidance) or the tool returns `{ error: ... }` and the LLM relays the message. No second Instruction gets persisted until the first terminates.

### Verification (what a reviewer runs)

- `bin/rails test` — all green, including new tests for each subscriber, the revision partial, the `StartGeneration` concurrency guard, and the `ProjectsController` fetch of `@active_revisions`.
- `bin/rails s` + `bin/dev` + manual walkthrough from step 1–5 above (via `bin/execute-instruction <id>` with a pre-seeded instruction, or via real chat flow with `bin/dev` running).

### Key Discoveries

- **Event contracts are frozen** (research §1). Step 6 adds subscribers; it does not add, rename, or re-shape events.
- **`@project.to_gid_param` is the stream name** — `include ActionCable::TestHelper` + `assert_broadcasts(stream_name, count)` is the test idiom in this repo (`test/jobs/chat_respond_job_test.rb:14`).
- **`after_create_commit :broadcast_append_message`** on `Message` broadcasts appends to `"messages"` target on `chat.project` stream — creating an assistant row from a subscriber automatically shows it in the chat. No direct broadcast call needed for the status line (`app/models/message.rb:5,15-22`).
- **`visible_in_chat?`** returns `true` for any `role: "user"` and for `role: "assistant"` with content or tool_calls (`app/models/message.rb:8-11`). A `role: :assistant, content: "✅ ..."` row renders immediately.
- **`.broadcast_append_later_to`** (used by `Message`) enqueues an ActiveJob. Tests need `perform_enqueued_jobs { assert_broadcasts(...) { ... } }` — same pattern as `chat_respond_job_test.rb:30-38`.
- **Instruction "non-terminal" phases** = `:researching | :planning | :implementing`. Only `:implementing` is ever set in Phase 2 (`app/tools/start_generation.rb:31`). Terminal = `:completed | :failed | :cancelled`.
- **Solid Queue `:generation` concurrency=1** (`config/queue.yml`) — a second Instruction would queue silently behind the first without a tool-level guard.

## What We're NOT Doing

- **`ChatFollowUpJob`** — the plan's stale LLM-follow-up job is not built. No post-generation LLM turn at all.
- **Personalized generation summary** ("Your app has 3 commits: CRUD, Tailwind, seed data…"). Status line is deterministic string.
- **Context-aware fresh `SuggestPrompts`** after generation. Pre-gen cards stay; no new card broadcast on completion.
- **Failure explanation via LLM** on `instruction.failed`. Just the bare status line.
- **Typed error event for `ChatRespondJob` rescue** (`TODO(Step 6)` marker in `chat_respond_job.rb:21`). Rename the marker only.
- **Revision retry / cancel UI**, **remediation details display**, **prompt text display** on cards (per decision A7).
- **`metrics` display** (`wall_seconds`, `exit_code`) on revision cards. Backend telemetry, not UI.
- **Defensive reset** of `git_sha` / `metrics` on `revision.started`. Partial branches on status; stale values invisible.
- **Historical revision browsing.** Only the currently-running instruction's revisions show; list vanishes when that instruction terminates.
- **Turbo-frame navigation semantics.** Plain `<div>` everywhere.
- **Revisions list restyling / empty-state polish.** Minimal Tailwind to match existing chat card vibe.

## Implementation Approach

Seven atomic commits in order. Each one leaves the app working and testable.

1. **View skeleton** — partial + container + controller query. Page renders cleanly with an empty slot when no instruction is running.
2. **Broadcast on create** — subscriber that fills the slot when `instruction.requested` fires.
3. **Broadcast on status change** — three subscribers for `revision.started/completed/failed` that replace individual cards.
4. **Terminal handling** — subscribers for `instruction.completed/failed` that persist an assistant status Message and clear the list.
5. **Tool guard** — `StartGeneration#execute` refuses if a non-terminal instruction already exists on the project.
6. **Prompt guidance** — one line in the system prompt telling the LLM not to try.
7. **TODO rename** — `# TODO(Step 6)` → `# TODO(later)` in `chat_respond_job.rb`.

Phase 1 is pure view work and tests a render, not a broadcast. Phases 2–4 are subscriber wiring with broadcast-assertion tests. Phase 5 is unit-testable tool logic. Phases 6 and 7 are text-only.

---

## Phase 1: revisions view + active slot

### Commit
`phase 2 step 6 (1/7): revisions view + active slot on projects#show`

### Overview

Add the revision card partial, the list wrapper partial, the controller query, and the empty container on the project show page. No event wiring yet. After this commit, the page renders without regression; there is a `<div id="active_revisions">` that is empty because no subscriber has filled it.

### Changes Required

#### 1. New file — `app/views/revisions/_revision.html.erb`

```erb
<div id="<%= dom_id(revision) %>" class="flex items-center gap-3 py-2">
  <% case revision.status %>
  <% when "pending" %>
    <span class="text-xs px-2 py-0.5 rounded bg-gray-200 text-gray-700">⏸ pending</span>
  <% when "generating" %>
    <span class="text-xs px-2 py-0.5 rounded bg-blue-200 text-blue-800">⏳ generating</span>
  <% when "completed" %>
    <span class="text-xs px-2 py-0.5 rounded bg-green-200 text-green-800">✅ completed</span>
  <% when "failed" %>
    <span class="text-xs px-2 py-0.5 rounded bg-red-200 text-red-800">❌ failed</span>
  <% end %>
  <span class="text-sm"><%= revision.summary %></span>
  <% if revision.completed? && revision.git_sha.present? %>
    <span class="text-xs font-mono text-gray-500 ml-auto"><%= revision.git_sha.first(7) %></span>
  <% end %>
</div>
```

#### 2. New file — `app/views/revisions/_list.html.erb`

```erb
<% if revisions.any? %>
  <div class="mb-6 p-4 border border-gray-200 rounded">
    <h2 class="text-sm font-semibold text-gray-600 mb-2">Current instruction</h2>
    <%= render partial: "revisions/revision", collection: revisions, as: :revision %>
  </div>
<% end %>
```

Empty state renders nothing — no layout shift when the slot is inactive.

#### 3. Edit — `app/controllers/projects_controller.rb`

Add `@active_revisions` to `#show`:

```ruby
def show
  @project = Project.find(params[:id])
  @messages = @project.chat.messages.order(:created_at)
  @active_revisions = active_revisions_for(@project)
end

private

def active_revisions_for(project)
  instruction = project.instructions
    .where.not(phase: %w[completed failed cancelled])
    .order(:created_at).last
  instruction&.revisions&.order(:position) || []
end
```

The `.where.not(phase: [...])` form lists terminal phases explicitly rather than non-terminal, so new non-terminal phases added later (e.g. if `:researching` is wired up in a later phase) are included without edits here.

#### 4. Edit — `app/views/projects/show.html.erb`

Insert the slot between `<h1>` and `#messages`:

```erb
<section class="w-full max-w-3xl mx-auto">
  <%= turbo_stream_from @project %>

  <h1 class="text-2xl font-semibold mb-4"><%= @project.name %></h1>

  <div id="active_revisions">
    <%= render "revisions/list", revisions: @active_revisions %>
  </div>

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

#### 5. New test — `test/controllers/projects_controller_show_test.rb`

```ruby
require "test_helper"

class ProjectsControllerShowTest < ActionDispatch::IntegrationTest
  setup do
    @project = Project.create!(name: "Shop")
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "flower shop")
  end

  test "renders empty active_revisions slot when no instruction exists" do
    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions", 1
    assert_select "div#active_revisions *", false  # slot exists but empty
  end

  test "renders active_revisions list when an implementing instruction has revisions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :pending,
      summary: "Add Task model", prompt: "p"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions h2", "Current instruction"
    assert_select "div#active_revisions", /Add Task model/
    assert_select "div#active_revisions", /pending/
  end

  test "hides revisions for terminal-phase instructions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :completed, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Done", prompt: "p", git_sha: "abc1234"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions *", false  # stays empty for terminal
  end

  test "renders git_sha (first 7 chars) on completed revision card" do
    # seed an implementing instruction with a completed revision inside it
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Add model", prompt: "p", git_sha: "abc1234deadbeef"
    )

    get project_url(@project)
    assert_select "div#active_revisions", /abc1234\b/
  end
end
```

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/controllers/projects_controller_show_test.rb` — 4 tests pass.
- [x] `bin/rails test` — full suite stays green (no regression on existing `projects` tests).

#### Manual Verification
- [x] `bin/dev`, open `/projects/new`, create a project, visit the show page. Page renders, nothing crashes. `#active_revisions` element is present in DOM (inspect) but empty.
- [x] No layout shift vs pre-Step 6 state.

**Implementation Note**: After this phase is green, pause for manual confirmation before moving to Phase 2.

---

## Phase 2: broadcast active revisions on instruction.requested

### Commit
`phase 2 step 6 (2/7): broadcast active revisions on instruction.requested`

### Overview

Add a subscriber that re-renders the full `revisions/list` partial into `#active_revisions` when `instruction.requested` fires. The pre-existing `instruction.requested` subscriber that enqueues `ExecuteInstructionJob` stays as-is. Two independent subscribers on the same event is fine and keeps concerns separated.

### Changes Required

#### 1. Edit — `config/initializers/event_subscribers.rb`

```ruby
# Routes ActiveSupport::Notifications to downstream side-effects:
# job enqueues, Turbo broadcasts, follow-up jobs.
#
# Subscribers MUST only enqueue jobs or broadcast Turbo Streams. No business
# logic here — that lives in the tool/job handlers.

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  ExecuteInstructionJob.perform_later(payload[:instruction_id])
end

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: instruction.revisions.order(:position) }
  )
end
```

The header comment's Step 5 / Step 6 notes are dropped since we're now in Step 6 and the file doesn't need to narrate its own history.

#### 2. New test — `test/integration/event_subscribers_test.rb`

```ruby
require "test_helper"

class EventSubscribersTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @project = Project.create!(name: "Shop")
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "flower shop")
    @instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    2.times do |i|
      @instruction.revisions.create!(
        project: @project, position: i, status: :pending,
        summary: "rev #{i}", prompt: "p"
      )
    end
    @stream_name = @project.to_gid_param
  end

  test "instruction.requested broadcasts the revisions list partial to active_revisions" do
    perform_enqueued_jobs do
      assert_broadcasts(@stream_name, 1) do
        ActiveSupport::Notifications.instrument(
          "instruction.requested",
          instruction_id: @instruction.id
        )
      end
    end
  end

  test "instruction.requested also enqueues ExecuteInstructionJob" do
    assert_enqueued_with(job: ExecuteInstructionJob, args: [ @instruction.id ]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end
end
```

**Note**: The second test uses `assert_enqueued_with` (ActiveJob test helper) without `perform_enqueued_jobs`, so it only verifies the enqueue and does not execute the `ExecuteInstructionJob` (which would shell out to `bin/roast`). Keep job assertions outside `perform_enqueued_jobs` in this file.

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/integration/event_subscribers_test.rb` — 2 tests pass.
- [x] `bin/rails test` — full suite stays green.

#### Manual Verification
- [x] `bin/dev`, create a project + chat, send a message that ends with `start_generation` being called. Watch `/projects/:id` — revision cards appear in `#active_revisions` as `⏸ pending` without a page reload.
- [ ] Open DevTools WebSocket frames tab; confirm a single `turbo-cable-stream-source` frame arrives when the instruction is created.

---

## Phase 3: broadcast revision card on status events

### Commit
`phase 2 step 6 (3/7): broadcast revision card on status events`

### Overview

Three subscribers, one per revision-level event (`revision.started`, `revision.completed`, `revision.failed`), that replace the individual `revision_<id>` card in the DOM. The factored form is a loop over event names since payload handling is identical — all three payloads carry `:revision_id` (the `:git_sha` and `:error` extras on completed/failed aren't read here; the partial reads them off the Revision model which is freshly loaded).

### Changes Required

#### 1. Edit — `config/initializers/event_subscribers.rb`

Append:

```ruby
%w[revision.started revision.completed revision.failed].each do |event|
  ActiveSupport::Notifications.subscribe(event) do |*, payload|
    revision = Revision.find(payload[:revision_id])
    Turbo::StreamsChannel.broadcast_replace_to(
      revision.project,
      target: ActionView::RecordIdentifier.dom_id(revision),
      partial: "revisions/revision",
      locals: { revision: revision }
    )
  end
end
```

#### 2. Edit — `test/integration/event_subscribers_test.rb`

Append:

```ruby
test "revision.started broadcasts a replace of the revision card" do
  revision = @instruction.revisions.first
  perform_enqueued_jobs do
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.started",
        revision_id: revision.id
      )
    end
  end
end

test "revision.completed broadcasts a replace of the revision card" do
  revision = @instruction.revisions.first
  revision.update!(status: :completed, git_sha: "deadbee1234567")
  perform_enqueued_jobs do
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.completed",
        revision_id: revision.id,
        git_sha: revision.git_sha
      )
    end
  end
end

test "revision.failed broadcasts a replace of the revision card" do
  revision = @instruction.revisions.first
  revision.update!(status: :failed)
  perform_enqueued_jobs do
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.failed",
        revision_id: revision.id,
        error: "exit 1"
      )
    end
  end
end
```

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/integration/event_subscribers_test.rb` — 5 tests pass (2 from Phase 2 + 3 new).
- [x] `bin/rails test` — full suite stays green.

#### Manual Verification
- [x] Run a full generation via `bin/execute-instruction <id>` against a real instruction with 2–3 revisions. Watch the show page — cards transition `⏸ pending → ⏳ generating → ✅ completed` (or `❌ failed`) without reloads. git SHA (first 7 chars) appears on completed cards.

---

## Phase 4: chat status message + list clear on instruction terminal

### Commit
`phase 2 step 6 (4/7): chat status message + list clear on instruction terminal`

### Overview

Two subscribers, one each for `instruction.completed` and `instruction.failed`. Both:

1. Persist a `role: :assistant` Message with a deterministic string. The Message's `after_create_commit :broadcast_append_message` callback appends it to the chat on its own — no explicit message broadcast needed in the subscriber.
2. Broadcast-replace `#active_revisions` with an empty list, clearing the slot.

On failure, the content names the failing revision by summary. Since `instruction.failed` fires only after `ExecuteInstructionJob#execute_revision` writes `status: :failed` on the offending row (`app/jobs/execute_instruction_job.rb:112-119`), the first-failed revision is always present in practice; a defensive `unless failed.nil?` fallback is still included for robustness.

### Changes Required

#### 1. Edit — `config/initializers/event_subscribers.rb`

Append:

```ruby
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  instruction.project.chat.messages.create!(
    role: :assistant,
    content: "✅ Generation finished."
  )
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end

ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  failed = instruction.revisions.where(status: :failed).order(:position).first
  content = failed ?
    "❌ Revision '#{failed.summary}' failed." :
    "❌ Generation failed."
  instruction.project.chat.messages.create!(role: :assistant, content: content)
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end
```

#### 2. Edit — `test/integration/event_subscribers_test.rb`

Append:

```ruby
test "instruction.completed persists an assistant status message" do
  perform_enqueued_jobs do
    assert_difference -> { @chat.messages.where(role: :assistant).count }, 1 do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end
  end

  msg = @chat.messages.where(role: :assistant).last
  assert_equal "✅ Generation finished.", msg.content
end

test "instruction.completed broadcasts both the status message and an empty list" do
  perform_enqueued_jobs do
    # Message.after_create_commit → 1 append broadcast
    # Subscriber → 1 replace broadcast of active_revisions
    assert_broadcasts(@stream_name, 2) do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end
  end
end

test "instruction.failed names the failing revision in the status message" do
  failing = @instruction.revisions.first
  failing.update!(status: :failed)

  perform_enqueued_jobs do
    ActiveSupport::Notifications.instrument(
      "instruction.failed",
      instruction_id: @instruction.id
    )
  end

  msg = @chat.messages.where(role: :assistant).last
  assert_equal "❌ Revision 'rev 0' failed.", msg.content
end

test "instruction.failed falls back to generic content if no revision is in failed status" do
  # edge case: all revisions still pending but instruction is marked failed
  perform_enqueued_jobs do
    ActiveSupport::Notifications.instrument(
      "instruction.failed",
      instruction_id: @instruction.id
    )
  end

  msg = @chat.messages.where(role: :assistant).last
  assert_equal "❌ Generation failed.", msg.content
end
```

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/integration/event_subscribers_test.rb` — 9 tests pass.
- [x] `bin/rails test` — full suite stays green.

#### Manual Verification
- [ ] Full generation end-to-end: trigger via chat, watch revision cards progress, observe list vanishing on completion and a `✅ Generation finished.` assistant bubble appearing in the chat.
- [ ] Trigger a failing generation (e.g. plant a revision prompt that will fail verification). Observe list vanishing and a `❌ Revision '...' failed.` assistant bubble.

---

## Phase 5: StartGeneration refuses concurrent instruction

### Commit
`phase 2 step 6 (5/7): StartGeneration refuses concurrent instruction`

### Overview

Add a tool-level guard at the top of `StartGeneration#execute`. If the project already has an instruction in a non-terminal phase, return `{ error: "..." }` without persisting anything or firing any notification. The LLM surfaces the error through the conversation.

### Changes Required

#### 1. Edit — `app/tools/start_generation.rb`

Insert at the top of `#execute`:

```ruby
def execute(intent:, clarifications: {})
  if @project.instructions.where.not(phase: %w[completed failed cancelled]).exists?
    return {
      error: "A generation is already in progress. Tell the user you'll start their next change once the current build finishes."
    }
  end

  # existing body unchanged from here
  result = CreatePlan.call(...)
  ...
end
```

The error message includes a concrete instruction for the LLM on how to frame the response back to the user. This keeps the user experience conversational even on refusal.

#### 2. Edit — `test/tools/start_generation_test.rb`

Append:

```ruby
test "refuses and persists nothing when an implementing instruction already exists" do
  @project.instructions.create!(
    user_intent: "earlier", description: "earlier",
    phase: :implementing, anchor_message: @user_message
  )

  payloads = []
  subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| payloads << p }

  result = nil
  assert_no_difference -> { Instruction.count } do
    assert_no_difference -> { Revision.count } do
      stub_create_plan(@plan) do
        result = @tool.execute(intent: "second build", clarifications: {})
      end
    end
  end

  assert result[:error].present?, "expected refusal to include an :error key"
  assert_match(/already in progress/, result[:error])
  assert_equal 0, payloads.size, "expected no instruction.requested notification"
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

test "does not refuse when all prior instructions are terminal" do
  @project.instructions.create!(
    user_intent: "earlier", description: "earlier",
    phase: :completed, anchor_message: @user_message
  )

  stub_create_plan(@plan) do
    result = @tool.execute(intent: "second build", clarifications: {})
    assert result[:instruction_id].present?
    refute result.key?(:error)
  end
end
```

### Success Criteria

#### Automated Verification
- [x] `bin/rails test test/tools/start_generation_test.rb` — all prior tests still pass + 2 new pass.
- [x] `bin/rails test` — full suite stays green.

#### Manual Verification
- [ ] Trigger a generation, then send a second build request mid-run (e.g. "also add auth"). LLM should respond conversationally without creating a second instruction. Verify via Rails console: `Instruction.count` increases by exactly 1 over the exchange.

---

## Phase 6: LLM rule against concurrent generations

### Commit
`phase 2 step 6 (6/7): LLM rule against concurrent generations`

### Overview

Add one bullet to the system prompt so the LLM is primed not to attempt a second `start_generation` call while one is in-flight. Defense-in-depth paired with Phase 5's tool-level guard.

### Changes Required

#### 1. Edit — `app/prompts/generator_agent/instructions.txt.erb`

Insert a bullet (placement: after the existing "summarise + suggest_prompts" bullet, before the trailing "You may also call `suggest_prompts`..." bullet):

```
- Do NOT call `start_generation` again while a previous generation is still running. If the user asks for more changes during a build, acknowledge their request and tell them you'll handle it as soon as the current build finishes. Keep the conversation moving — don't go silent.
```

No test. Prompt content is only observable via live LLM behavior.

### Success Criteria

#### Automated Verification
- [x] `bin/rails test` — full suite stays green (the prompt file is read in `ChatRespondJobTest`; assertions compare against the file content, not a hardcoded string, so no test needs updating).

#### Manual Verification
- [ ] Same "also add auth" mid-run test from Phase 5. LLM should now decline without even trying `start_generation` in most runs — observable by the absence of a `start_generation` tool call pill in the chat during the refusal turn.

---

## Phase 7: defer chat error UX TODO marker

### Commit
`phase 2 step 6 (7/7): defer chat error UX TODO marker`

### Overview

Housekeeping only. The `# TODO(Step 6)` at `app/jobs/chat_respond_job.rb:21` is a signal that Step 6 would address chat error UX. Per this plan's decision (Q8, out of scope), the concern is deferred. Rename the marker so it doesn't mis-signal future readers.

### Changes Required

#### 1. Edit — `app/jobs/chat_respond_job.rb`

Change line 21:

```diff
-    # TODO(Step 6): typed error event + proper UX
+    # TODO(later): typed error event + proper UX
```

### Success Criteria

#### Automated Verification
- [x] `bin/rails test` — full suite stays green.
- [x] `git grep "TODO(Step 6)" -- app/ lib/ config/ test/ bin/` returns no results (thoughts/ is archival and unchanged).

#### Manual Verification
- [x] N/A — text-only change.

---

## Testing Strategy

### Unit tests
- **Revision partial rendering** — Phase 1's controller test exercises the partial through ERB (via `assert_select` on the rendered response).
- **StartGeneration guard** — Phase 5's new tests in `test/tools/start_generation_test.rb`.
- **Subscribers** — Phase 2/3/4's `test/integration/event_subscribers_test.rb` uses `ActionCable::TestHelper.assert_broadcasts(stream_name, count)` + `perform_enqueued_jobs` to capture broadcasts from the `Message` callback and the explicit subscriber-level calls.

### Integration test (end-to-end)
Not part of Step 6. Phase 2 Step 7 (per the main plan `docs/03-plans/01-phase-2-poc-generator-app.md` § Step 7) owns the "todo_list plan + CLI" E2E integration test that will cover Step 6 wiring as a side effect.

### Manual walkthrough
1. `bin/dev` to start web + Solid Queue worker + Tailwind watcher.
2. Create a project via `/projects/new` with a short description.
3. On the show page, confirm empty `#active_revisions` slot.
4. Continue the chat until LLM calls `start_generation`.
5. Observe cards appearing + transitioning live.
6. Observe list clearing + assistant status line on terminal.
7. Send another build request mid-run — verify refusal.

## Performance Considerations

- **Solid Cable writes per instruction**: 1 (on `requested`) + 2N (started + terminal on each of N revisions) + 1 (terminal instruction replace) + 1 (assistant message append) = `2N + 3` rows in `solid_cable_messages`. For N=3 this is 9 rows. Negligible at Phase 2 scale.
- **Subscriber DB queries per event**: one `find` per event. Acceptable — these are event-driven, not hot-path.
- **Message.after_create_commit** is `broadcast_append_later_to` → enqueues an ActiveJob. In dev/prod this means the assistant status message broadcast is asynchronous. In tests, `perform_enqueued_jobs` resolves it synchronously.

No N+1 concerns (all queries are scalar find-by-id), no added indexes needed.

## Migration Notes

No schema changes. No data migration.

## References

- Research document: `../research/2026-04-20/phase-2-step-6-events-turbo-followup.md`
- Phase 2 plan: `docs/03-plans/01-phase-2-poc-generator-app.md` § "Step 6" (line 393)
- Prior step plan: `./thoughts/shared/plans/2026-04-20/phase-2-step-5-execute-instruction-job.md`
- Event emission sites:
  - `app/tools/start_generation.rb:48-51` (instruction.requested)
  - `app/jobs/execute_instruction_job.rb:77` (revision.started)
  - `app/jobs/execute_instruction_job.rb:107-111` (revision.completed)
  - `app/jobs/execute_instruction_job.rb:114-118` (revision.failed)
  - `app/jobs/execute_instruction_job.rb:22-25` (instruction.completed/failed)
- Broadcast pattern to mirror: `app/jobs/chat_respond_job.rb:34-41`
- Test idiom: `test/jobs/chat_respond_job_test.rb:30-38`, `test/tools/start_generation_test.rb:62-77`
