---
date: 2026-05-05
researcher: Paweł Strzałkowski
status: ready
tags: [chat-agent, prompts, generator-agent, event-subscribers, message-rendering, anthropic-pairing]
related_research: thoughts/shared/research/2026-05-04/chat-agent-prompt-mimicking-issues.md
---

# Chat-agent: render build status as derived events, not as Messages

## Overview

Stop persisting `🌀 Building: …`, `✅ Generation finished.`, and `❌ … failed.` rows into the `messages` table. Render build status from data we already have — the tool-call's stored arguments for the start signal, and the `Instruction` row's terminal state for the end signal — so the LLM never sees its own past "voice" saying things it never said. Plus two surgical prompt-text rewrites (line 18 of the agent prompt and the no-pending branch of the auto-recap nudge) to remove the mimicry seeds and the past-tense narration.

## Current State Analysis

Three subscribers in `config/initializers/event_subscribers.rb` create `Message` rows directly:

- `event_subscribers.rb:34-40` — `instruction.requested` → persists `Message(role: :assistant, content: "🌀 Building: #{description}")`
- `event_subscribers.rb:54-59` — `instruction.completed` → persists `Message(role: :assistant, content: "✅ Generation finished.")`
- `event_subscribers.rb:111-117` — `instruction.failed` → persists `Message(role: :assistant, content: "❌ ... failed.")`

These rows are indistinguishable from genuine LLM output in `chat.messages`, so RubyLLM's `acts_as_chat#to_llm` (gem `lib/ruby_llm/active_record/chat_methods.rb:78-94`) feeds them back to the model as few-shot history. The post-merge real-Haiku smoke (`tmp/local_todo_app_with_modifications.log`) confirmed the model imitates them on subsequent turns, producing duplicate `🌀 Building…` bubbles after every mutation tool call and emitting `✅ Generation finished.` in the post-`suggest_prompts` text slot ~30-50s before the build actually finishes.

Independently, `event_subscribers.rb:90-100` (the auto-recap nudge body) instructs the LLM to "acknowledge that the build finished and ask what they want next" in the no-pending-messages branch. The LLM honours the first half ("Done! Your green banner is now at the top.") and skips the question.

The smoke also confirmed three orthogonal pieces work correctly and must be preserved:

- `app/agents/generator_agent.rb:6-14` — workspace-aware tool gating (1× `create_application`, then 3× `modify_application`, zero rebuilds)
- STATE B prompt branch in `app/prompts/generator_agent/instructions.txt.erb:11-14` — no mutation tool calls during in-progress builds
- The auto-recap branch-1 path (mid-build messages get recapped and confirmed) at `event_subscribers.rb:90-100`

The user-facing UI today already filters synthetic rows correctly:

- `app/models/message.rb:8-12` (`visible_in_chat?`) — hides `system_injected: true` rows from chat
- `app/views/messages/_message.html.erb:6-10` — uses `render_as_pill?` + `tool_call_pill_text` for tool-call assistant messages
- `app/helpers/messages_helper.rb:8-19` — pill text helper, currently only handles `create_application` and `suggest_prompts` cases

The data model already carries everything we need to derive status without new Messages:

- `tool_calls.arguments` (json column at `db/schema.rb:150`) — stores `{intent: ..., clarifications: {...}}`, available the moment the tool_call attaches
- `instructions.phase` (enum at `app/models/instruction.rb:6-13`) and `instructions.updated_at` (set when phase transitions to `:completed` or `:failed`; instructions are not updated after that)
- `instructions.description` — the planner-polished task description

## Desired End State

After this plan completes:

- No `Message` row in any chat is created by `instruction.requested`, `instruction.completed`, or `instruction.failed` subscribers. Every row in `messages` is either user-typed, LLM-streamed, or the auto-recap synthetic user nudge.
- The chat UI renders **start signals** as text on the existing tool-call pill (`🌀 Build started: <intent>`, where `<intent>` reads from `tool_calls.arguments`).
- The chat UI renders **end signals** as a separate "status row" partial whose source is the `Instruction` row itself, interleaved with `Messages` by timestamp at view-build time and broadcast on state transition.
- `Chat#to_llm` continues to iterate `chat.messages` with no override — there is no system-emitted assistant content for the LLM to mimic.
- Calling `bin/inspect-chat` against any chat from a successful generation reports `✓ No structural issues detected.`
- The agent prompt at `instructions.txt.erb:18` no longer mentions the literal `"🌀 Building…"` string.
- The auto-recap nudge body's no-pending-messages branch forbids past-tense completion claims and requires a question.

### Verification:

- `bin/inspect-chat <project_id>` after a fresh build run prints clean pairing.
- Manual: build a todo list, then add a green banner, then add a footer, then send two mid-build messages — UI shows `🌀 Build started: …` pill on each tool-call message and `✅ Built` row at the bottom of chat at completion. No duplicate "Building…" or premature "✅ Generation finished." bubbles. Auto-recap response asks a question instead of narrating "Done!".
- `chat.messages.where("content LIKE '🌀%' OR content LIKE '✅%' OR content LIKE '❌%'").count == 0` after a full build cycle.

### Key Discoveries:

- Tool result already carries the start signal: `app/tools/modify_application.rb:62-66` returns `{instruction_id, revision_count, instruction_description}` — the LLM doesn't need a separate assistant Message to know a build started.
- `tool_calls.arguments` is a JSON column readable directly: `app/models/tool_call.rb` + `db/schema.rb:150`.
- `ToolCall.after_commit :touch_message` (`app/models/tool_call.rb:13-19`) already triggers a re-render of the parent Message once the tool_call attaches — the pill picks up the new helper output for free.
- `Instruction.updated_at` is reliable as the completion timestamp: phase transitions to `:completed` or `:failed` are the last touch (no callbacks update instructions after that).
- The interleaved "🌀 Building" Message in today's chat sits *between* the assistant `tool_use` and the `tool_result` (i.e., between message N and N+2). Removing it restores the canonical `tool_use → tool_result` adjacency Anthropic expects — a structural improvement, not a regression.

## What We're NOT Doing

- **No `Chat#to_llm` override.** The user vetoed redefining RubyLLM internals. We don't need to filter because the rows we used to filter no longer exist.
- **No new `system_injected`-style flag, no new column on `messages`.** The structural fix removes the conflict at the source.
- **No new `chat_events` table.** Phantom rows derive from the existing `instructions` table at view time.
- **No FK between `Instruction` and `tool_calls`.** Pill renders from tool_call alone; phantom row renders from instruction alone — they're independent.
- **No backfill migration for legacy chat history.** Operator clears existing projects (`Project.destroy_all` via console) post-deploy in dev; production carries no meaningful chat history yet.
- **Not touching `latest_streaming_assistant`** (`app/jobs/chat_respond_job.rb:71-73`). Pre-existing race risk; out of scope.
- **Not changing the `RubyLLM::BadRequestError` handling** in `chat_respond_job.rb:39-53`. The "start a new project" friendly message stays.
- **Not changing the auto-recap branch-1 behavior** (mid-build message recap). Branch-1 worked correctly in the smoke.
- **Not changing STATE A / STATE B prompt branches.** Both worked correctly in the smoke.

## Implementation Approach

Four atomic phases. Each leaves the codebase functional and tested. Phases 1+2 are the structural fix; phases 3+4 are surgical prompt rewrites that close the remaining seams.

Order: 1 → 2 → 3 → 4. Phase 4 is independent and could ship in any order, but writing it last keeps the structural-then-text gradient clean.

---

## Phase 1: Build-started pill from tool_call arguments

### Commit
`chat-agent: render Build started pill from modify/create tool_call`

### Overview

Stop creating the `🌀 Building: …` Message row on `instruction.requested`. Render the same information by extending `tool_call_pill_text` to read `tool_calls.arguments[:intent]` for `modify_application` and `create_application` tool calls.

### Changes Required:

#### 1. Extend the pill helper AND make the partial render the pill independently of text content
**File**: `app/helpers/messages_helper.rb`
**Changes**: Rewrite `tool_call_pill_text` to read intent from the first tool_call's arguments. Delete `render_as_pill?` — the partial no longer needs a conjunction predicate (see file 2).

```ruby
def tool_call_pill_text(message)
  call = message.tool_calls.first
  case call&.name
  when "create_application", "modify_application"
    intent = call.arguments["intent"].to_s
    intent.empty? ? "🌀 Build started" : "🌀 Build started: #{intent}"
  when "suggest_prompts"
    "preparing suggestions…"
  else
    "running: #{message.tool_calls.map(&:name).uniq.join(", ")}"
  end
end
```

The single existing `case names ... when ["create_application"]` shape doesn't survive — it's reading an array and only matched one specific tool. We replace it with a `case call&.name` shape that reads the first tool_call's name, which is robust to messages that batch multiple tool_calls.

**File**: `app/views/messages/_message.html.erb`
**Changes**: Split the `render_as_pill? ? pill : body` conjunction into two independent renders. The pill renders whenever the assistant message has any tool_calls; the body renders whenever the content is non-empty. Both can render in the same bubble — if the LLM ever emits prose alongside a tool_use, the user sees both, not just one. This eliminates the silent-loss-of-pill failure mode when a chatty model emits text in the same turn as the tool call.

```erb
<div id="<%= dom_id(message) %>" class="<%= message_row_class(message) %>">
  <% if message.visible_in_chat? %>
    <div class="msg-bubble">
      <div class="msg-role"><%= message.role %></div>

      <% if message.role == "assistant" && message.tool_calls.any? %>
        <div class="msg-pill"><%= tool_call_pill_text(message) %></div>
      <% end %>
      <% if message.content.to_s.strip.present? %>
        <div class="msg-body"><%= message.content %></div>
      <% end %>
    </div>
  <% end %>
</div>
```

#### 2. Drop the subscriber Message creation
**File**: `config/initializers/event_subscribers.rb`
**Changes**: Delete the fourth `instruction.requested` subscriber (lines 30-40 — the one that posts `🌀 Building: ...`). Keep the other three: `ExecuteInstructionJob.perform_later` enqueue at lines 7-9, the revisions-list broadcast at lines 11-19, and the `StopPreviewJob` enqueue at lines 25-28.

```ruby
# DELETE this block from event_subscribers.rb:30-40:
ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  instruction.project.chat.messages.create!(
    role: :assistant,
    content: "🌀 Building: #{instruction.description}"
  )
end
```

#### 3. Update existing tests
**File**: `test/integration/event_subscribers_test.rb`
**Changes**: Delete the test at lines 76-87 ("instruction.requested persists a 🌀 Building assistant message"). Other tests in this file are unaffected by this phase.

**File**: `test/agents/generator_agent_test.rb` (or new `test/helpers/messages_helper_test.rb`)
**Changes**: Add coverage for the new pill branches (one happy-path test per tool name, one for empty intent fallback).

```ruby
test "tool_call_pill_text renders Build started for modify_application" do
  message = messages(:assistant_with_modify_tool_call)
  assert_equal "🌀 Build started: make banner green",
               helper.tool_call_pill_text(message)
end

test "tool_call_pill_text falls back to generic when intent missing" do
  # tool_call.arguments = {} edge case
end
```

### Success Criteria:

#### Automated Verification:
- [x] All tests pass: `bin/rails test`
- [x] Linting passes: `bundle exec rubocop` (if configured) or whatever the repo uses
- [x] No `🌀 Building` rows are created during the existing event_subscribers integration test sweep

#### Manual Verification:
- [ ] Create a fresh project, type "build a todo list", confirm — the assistant tool-call bubble shows `🌀 Build started: build a todo list` (or whatever the user's intent was).
- [ ] No second duplicate `🌀 Building…` bubble appears below the pill.
- [ ] After build completes, the chat continues to work (auto-recap nudge fires; LLM responds).
- [ ] `bin/inspect-chat <project_id>` reports `✓ No structural issues detected.`

**Implementation Note**: After Phase 1's automated verification passes, pause for manual confirmation that a fresh project shows the new pill correctly before proceeding to Phase 2.

---

## Phase 2: Phantom status rows from completed/failed Instructions

### Commit
`chat-agent: render generation completion as derived chat row`

### Overview

Stop creating the `✅ Generation finished.` and `❌ … failed.` Message rows on `instruction.completed` / `.failed`. Instead, render a `instructions/_status_row` partial keyed off `dom_id(instruction)` and interleave it into the chat by timestamp at view-build time. Subscribers switch to broadcasting an append of the partial.

### Changes Required:

#### 1. Add the status row partial
**File**: `app/views/instructions/_status_row.html.erb` (new)
**Changes**: Render the instruction's terminal state as a chat-style row.

```erb
<div id="<%= dom_id(instruction) %>_status" class="msg msg-asst">
  <div class="msg-bubble">
    <div class="msg-pill">
      <% if instruction.completed? %>
        ✅ Built
      <% elsif instruction.failed? %>
        <% failed_rev = instruction.revisions.where(status: :failed).order(:position).first %>
        <% if failed_rev %>
          ❌ Build failed: <%= failed_rev.summary %>
        <% else %>
          ❌ Build failed
        <% end %>
      <% end %>
    </div>
  </div>
</div>
```

The partial uses `dom_id(instruction) + "_status"` to disambiguate from any other rendering of the same Instruction (e.g., active_revisions). This avoids broadcast target collisions.

#### 2. Build the merged chat-events stream in the controller
**File**: `app/controllers/projects_controller.rb`
**Changes**: Replace `@messages = @project.chat.messages.order(:created_at)` with a merged event list.

```ruby
def show
  @chat_events = build_chat_events(@project)
  @active_revisions = active_revisions_for(@project)
end

private

def build_chat_events(project)
  messages = project.chat.messages.includes(:tool_calls).to_a
  status_instructions = project.instructions
    .where(phase: %w[completed failed])
    .to_a
  (messages + status_instructions).sort_by { |e| event_timestamp(e) }
end

def event_timestamp(event)
  case event
  when Message     then event.created_at
  when Instruction then event.updated_at
  end
end
```

#### 3. Replace the `@messages` view loop with a dispatch
**File**: `app/views/projects/show.html.erb`
**Changes**: At line 17, swap the message-only render for a per-event dispatch.

```erb
<div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">
  <% @chat_events.each do |event| %>
    <% case event %>
    <% when Message %>
      <%= render partial: "messages/message", locals: { message: event } %>
    <% when Instruction %>
      <%= render partial: "instructions/status_row", locals: { instruction: event } %>
    <% end %>
  <% end %>
</div>
```

#### 4. Switch completion / failure subscribers from Message-create to broadcast_append
**File**: `config/initializers/event_subscribers.rb`
**Changes**:

- Replace `instruction.completed` lines 54-59 (the `chat.messages.create!(... "✅ Generation finished.")` block) with a `broadcast_append_later_to` of the status row partial.
- Replace `instruction.failed` lines 111-117 (the `chat.messages.create!(... "❌ ... failed.")` block) with a `broadcast_append_later_to` of the status row partial.
- Keep the rest of each subscriber intact (revisions broadcast, auto-recap nudge enqueue, etc.).

```ruby
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  Turbo::StreamsChannel.broadcast_append_later_to(
    instruction.project,
    target: "messages",
    partial: "instructions/status_row",
    locals: { instruction: instruction }
  )
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end

# (auto-recap subscriber at lines 75-109 stays unchanged)

ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  Turbo::StreamsChannel.broadcast_append_later_to(
    instruction.project,
    target: "messages",
    partial: "instructions/status_row",
    locals: { instruction: instruction }
  )
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end
```

#### 5. Update existing tests
**File**: `test/integration/event_subscribers_test.rb`
**Changes**:

- Delete the test at lines 89-99 ("instruction.completed persists an assistant status message").
- Rewrite the test at lines 101-114 ("instruction.completed broadcasts both the status message and an empty list") — now it broadcasts the `instructions/_status_row` partial + the empty revisions list. Assert two broadcasts, content matches the partial.
- Delete the tests at lines 167-178 ("instruction.failed names the failing revision in the status message") and 180-188 ("instruction.failed falls back to generic content if no revision is in failed status").
- Add new tests for `instruction.completed` / `.failed` that assert a `broadcast_append_later_to` of the status_row partial (using `assert_broadcast_on` with the rendered partial output, or equivalent ActionCable test helpers).

```ruby
test "instruction.completed broadcasts a status_row partial appended to messages" do
  perform_enqueued_jobs(except: ChatRespondJob) do
    assert_broadcasts(@stream_name, 2) do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end
  end
  # Assert one of the broadcasts targets the messages dom and renders ✅ Built
end

test "instruction.failed names the failing revision in the status row" do
  failing = @instruction.revisions.first
  failing.update!(status: :failed)

  ActiveSupport::Notifications.instrument(
    "instruction.failed",
    instruction_id: @instruction.id
  )

  # Assert the broadcast payload contains "❌ Build failed: rev 0"
end
```

**File**: `test/integration/modify_application_after_completion_test.rb`
**Changes**: If this test asserts `✅ Generation finished.` Message rows in chat history, update it to assert phantom-row broadcasts instead. Otherwise no change.

#### 6. Drop the now-orphaned auto-recap "no messages" path? — NO
The auto-recap subscriber's `pending` query at `event_subscribers.rb:79-81` already handles the empty case via `pending.empty?`. No change here.

### Success Criteria:

#### Automated Verification:
- [x] All tests pass: `bin/rails test`
- [x] No `✅ Generation finished.` or `❌ ... failed.` Message rows are created during the integration test sweep
- [x] `bin/inspect-chat` against a chat with a completed instruction reports clean pairing
- [x] `project.chat.messages.count + project.instructions.where(phase: %w[completed failed]).count == build_chat_events(project).count` (sanity invariant — every chat event comes from exactly one of these two sources)

#### Manual Verification:
- [ ] Build flow completes: `🌀 Build started: …` pill while running, `✅ Built` row appears at the bottom of chat at completion, auto-recap LLM response follows.
- [ ] Mid-build user messages: send 2 mid-build messages, confirm the `✅ Built` row appears between the user's last mid-build message and the auto-recap response, ordered correctly by timestamp.
- [ ] Page reload during/after build: chat re-renders correctly with the same interleaving (no rows appearing in wrong order).
- [ ] Failure path: deliberately cause a build to fail (e.g., kill the worker mid-revision); chat shows `❌ Build failed: <revision summary>` row, auto-recap fires (failure also runs the auto-recap subscriber? — verify).
- [ ] `bin/inspect-chat <project_id>` reports `✓ No structural issues detected.`

**Implementation Note**: After Phase 2's automated verification passes, pause here for the manual smoke described above. This is the highest-risk phase for visual regressions. Proceed to Phase 3 only after manual confirmation.

---

## Phase 3: Drop the literal status string from the agent prompt

### Commit
`chat-agent: stop quoting system status strings in agent prompt`

### Overview

`instructions.txt.erb:18` references the literal `🌀 Building…` text — a dead reference once Phase 1 lands, and a residual mimicry seed for build #1 in any chat (where prior history doesn't yet contain the few-shot pattern, but the prompt itself does). Rewrite the post-tool slot rule in plain language without quoting any UI label.

### Changes Required:

#### 1. Rewrite line 18 AND tighten the State A tool-call rule
**File**: `app/prompts/generator_agent/instructions.txt.erb`
**Changes**: Two edits to the same file.

(a) Replace line 18 with a constraint that doesn't quote the literal status string and that explicitly forbids both build-started and completion-finished narration in any post-tool slot.

```erb
- After `create_application` or `modify_application` returns, leave your text response empty. Then call `suggest_prompts` with 3-5 natural next steps. After `suggest_prompts` returns, leave the next text response empty as well. Do not narrate that a build started or finished — those events surface in the UI on their own; you don't need to announce them.
```

The shape difference vs. the existing line 18: removes `"🌀 Building…"` literal mention; constrains BOTH post-tool text slots (after the mutation tool AND after `suggest_prompts`); explicitly forbids "started"/"finished" narration in plain language without quoting any specific string.

(b) Append one sentence to the State A bullet about calling the mutation tool (currently line 8). Symmetric with (a): silences the *pre*-tool slot in the same turn as the tool call.

```erb
- Only AFTER the user's NEXT message confirms ("yes", "go ahead", "do it", "proceed", or any clear affirmation), call `create_application` (for a brand-new project) OR `modify_application` (for a change to an existing app). Only ONE of these tools is bound at any time — use whichever is offered. When you make this tool call, the tool call is your entire response — do not write any prose alongside it. The UI shows a build-started indicator on its own.
```

Why both edits: the start-signal pill in Phase 1 renders independently of text content (after the partial change in Phase 1 step 1), so a chatty tool-use turn no longer silently loses the pill — but suppressing the prose in the first place keeps the chat clean and avoids the user reading "Got it, building now" in the same bubble as the pill. Belt and suspenders; one prevents the awkward UX, the other is the structural guarantee.

#### 2. (no test needed for prompt text)
The agent prompt is rendered at runtime; behavioural tests against it require LLM stubs. The structural smoke (Phase 5 verification) is sufficient.

### Success Criteria:

#### Automated Verification:
- [x] All tests pass: `bin/rails test`
- [x] `grep -n "🌀\|Building…\|✅\|Generation finished" app/prompts/generator_agent/instructions.txt.erb` returns nothing

#### Manual Verification:
- [ ] Real-Haiku run of build → modify → modify shows no LLM-emitted assistant turn containing `🌀` or `✅` or `❌` symbols.
- [ ] Auto-recap response after a no-mid-build-message build still asks a question (Phase 4 fixes this; if Phase 3 lands first, branch-2 narration may still be "Done!"-style — that's OK, Phase 4 finishes it).

**Status:** Phase 3 was rolled into the suggest_prompts removal (see "Deviation" note below the plan body). Both edits — drop literal `🌀 Building…` from the prompt, and add the State A "tool call is your entire response" rule — were applied as part of `app/prompts/generator_agent/instructions.txt.erb` rewrite.

---

## Phase 4: Tighten the auto-recap nudge body's no-pending branch

### Commit
`chat-agent: forbid past-tense completion claims in auto-recap`

### Overview

`event_subscribers.rb:90-100` (the `nudge_body` heredoc) tells the LLM in branch 2 to "acknowledge that the build finished and ask what they want next." The smoke shows the LLM honours the first half ("Done! Your green banner is now at the top of the page.") and skips the question. Tighten branch 2 to forbid past-tense claim language and require a question.

### Changes Required:

#### 1. Rewrite branch 2 of the nudge body
**File**: `config/initializers/event_subscribers.rb`
**Changes**: Replace the body at lines 90-100. Branch 1 (mid-build messages exist) stays as-is — the smoke confirmed it works correctly.

```ruby
nudge_body = <<~NUDGE
  [Auto-resume after instruction ##{instruction.id} completed.]

  Messages the user sent while the build was running:
  #{pending_section}

  Your job in this turn:
  1. If the user sent change requests during the build, recap them in 1-2 sentences and ask whether to proceed (without applying anything yet).
  2. If they sent no change requests (or only questions), greet them in ONE short sentence and END with a question asking what they want next. Do NOT use past-tense completion language ("Done", "Built", "Finished", "Updated", "Applied"). The completion is shown elsewhere in the UI; your job is to invite the next move.
  3. DO NOT call create_application or modify_application. DO NOT call any other tool. Reply with text only.
NUDGE
```

The shape difference: branch 2 explicitly forbids the words the LLM was producing ("Done", "Built", etc.), explicitly requires a question, references the UI completion signal so the LLM understands it's not the bearer of completion news.

#### 2. Update existing tests
**File**: `test/integration/event_subscribers_test.rb`
**Changes**: The two tests at lines 143-155 ("lists pending mid-build user messages in the nudge body") and 157-165 ("includes a 'no messages' marker") should still pass — content assertions don't conflict with the new branch-2 wording. Add one new test asserting the new branch-2 phrasing forbids the past-tense words list.

```ruby
test "branch 2 of the nudge body forbids past-tense completion claims" do
  ActiveSupport::Notifications.instrument(
    "instruction.completed",
    instruction_id: @instruction.id
  )
  nudge = @chat.messages.where(system_injected: true).order(:id).last
  assert_match(/Do NOT use past-tense/, nudge.content)
  assert_match(/END with a question/, nudge.content)
end
```

### Success Criteria:

#### Automated Verification:
- [x] All tests pass: `bin/rails test`

#### Manual Verification:
- [ ] Real-Haiku run of build → no mid-build messages → auto-recap response asks a question and does NOT contain "Done!" / "Built" / "Finished" / "Updated".
- [ ] Real-Haiku run of build → mid-build messages → branch 1 still recaps and asks "should I apply both?" (regression check).

---

## Phase 5 (optional but recommended): Stubbed-LLM regression test

### Commit
`chat-agent: integration test asserting no status text in LLM context`

### Overview

A lightweight regression net: build a chat with a completed instruction, call `chat.to_llm`, and assert the LLM-bound message array contains zero `🌀 Building`, `✅ Generation finished.`, or `❌` strings. Catches future drift if anyone re-introduces a subscriber-driven Message.

### Changes Required:

#### 1. New integration test
**File**: `test/integration/chat_to_llm_excludes_status_text_test.rb` (new)
**Changes**: Test that simulates a build cycle (without invoking an LLM) and asserts the message array fed to RubyLLM contains only genuine turns.

```ruby
require "test_helper"

class ChatToLlmExcludesStatusTextTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "test", user: users(:owner))
    @chat = GeneratorAgent.create!(project: @project)
  end

  test "completed instructions do not insert status text into the LLM message stream" do
    @chat.messages.create!(role: :user, content: "build x")
    instruction = @project.instructions.create!(
      user_intent: "build x", description: "build x",
      phase: :implementing, anchor_message: @chat.messages.first
    )

    ActiveSupport::Notifications.instrument(
      "instruction.requested",
      instruction_id: instruction.id
    )

    instruction.update!(phase: :completed)
    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: instruction.id
    )

    llm_messages = @chat.to_llm.messages.map(&:content).join("\n")
    refute_includes llm_messages, "🌀 Building"
    refute_includes llm_messages, "✅ Generation finished"
    refute_includes llm_messages, "❌"
  end
end
```

### Success Criteria:

#### Automated Verification:
- [x] Test passes: `bin/rails test test/integration/chat_to_llm_excludes_status_text_test.rb`
- [x] Reverting Phase 1 or Phase 2 makes this test fail (sanity check that the test catches the regression it claims to)

---

## Testing Strategy

### Unit / helper tests:
- `tool_call_pill_text` for `modify_application` / `create_application` happy path (intent present)
- `tool_call_pill_text` for `modify_application` with empty intent (fallback)
- `tool_call_pill_text` for unknown tools (existing behaviour preserved)

### Integration tests:
- `event_subscribers_test.rb` — rewritten broadcasts, no Message-create
- `chat_to_llm_excludes_status_text_test.rb` — new regression net (Phase 5)
- `modify_application_after_completion_test.rb` — verify auto-recap flow still works after the structural changes

### Manual smoke (real Haiku, blocking before each phase pause):
1. New project, "build a todo list" → confirm → build runs → `🌀 Build started: build a todo list` pill, `✅ Built` row at bottom on completion, auto-recap asks a question.
2. Same project, "add a green banner" → confirm → second build runs → second pair of pill+row, auto-recap asks again.
3. Same project, "add a green footer" → confirm → during build, send "make background red" + "yes, change banner to yellow" → wait for completion → auto-recap recaps both mid-build messages and asks "should I apply both?" → user says yes → build runs → preview restarts.
4. `bin/inspect-chat <project_id>` after step 3 — reports `✓ No structural issues detected.`

## Performance Considerations

- The controller's `build_chat_events` does two queries (`messages` + `instructions`) and merges in Ruby. For chats with hundreds of messages and dozens of completed instructions, this is still O(n log n) on tiny n. No pagination concerns at current scale.
- Broadcasts: each `instruction.completed` now fires 2 broadcasts (status row append + revisions list replace) instead of the old pattern (Message create — which fanned out via `broadcast_append_message` AND a separate `broadcast_replace_to`). Net broadcast count is unchanged.
- The pill helper does one `case` statement on a single attribute read — negligible.

## Migration Notes

**Before deploying**: clear local dev DB of pre-existing chats whose history contains the old subscriber-emitted Messages. Those rows will continue feeding the LLM context for those specific chats.

```ruby
# In Rails console, post-merge, pre-smoke:
Project.destroy_all
```

Production has no meaningful chat history yet (Phase 4d is unmerged on `phase-4d-deploy-and-wrapup`), so no production cleanup is required.

If a chat ever needs preserving across this change, run a content-pattern-based DELETE:

```sql
DELETE FROM messages
WHERE content LIKE '🌀 Building: %'
   OR content = '✅ Generation finished.'
   OR content LIKE '❌ %failed.';
```

Strings are sufficiently unique that false-positive risk is essentially zero.

## Known Limitations

- **Phantom-row broadcast is non-idempotent.** `broadcast_append_later_to(target: "messages", partial: "instructions/status_row")` produces a `<div id="instruction_<id>_status">` keyed off a stable derived id. If `instruction.completed` (or `.failed`) ever fires twice for the same instruction — e.g., a `retry_on` added later to `ExecuteInstructionJob`, manual re-instrumentation from a console, a future test that combines flows — the browser appends a second div with a duplicate HTML id. The Message-based predecessor was naturally immune via autoincrement. Treat `instruction.completed` / `.failed` instrumentation as an at-most-once contract for now. If this ever becomes a real problem, fix with either an `instructions.terminated_at` column (idempotent guard at the DB level + a non-fragile ordering key — see next bullet) or a `Rails.cache.write(..., unless_exist: true)` guard at the subscriber.

- **Phantom-row ordering depends on `instruction.updated_at` being frozen post-termination.** `build_chat_events` sorts `Instruction` rows by `updated_at`, which today coincides with the moment the phase transitioned to `:completed` / `:failed` (no callback or feature touches an instruction after that). Any future feature that mutates a terminated instruction — cancel-then-acknowledge, retry-failed, an admin annotation, a `seen_by_user_at`, a counter cache, or even `touch: true` on a new association — will silently advance `updated_at` and reorder the phantom row in chat history. The failure is subtle (no error, just chat that visually shuffles when nothing happened). Revisit when adding cancel/retry/seen-tracking; the structural fix is an `instructions.terminated_at` column set once on the phase transition.

## References

- Original research: `thoughts/shared/research/2026-05-04/chat-agent-prompt-mimicking-issues.md`
- Precursor plan: `thoughts/shared/plans/2026-05-04/chat-agent-tweak-rebootstrap-and-deferred-handling.md`
- Existing pill helper: `app/helpers/messages_helper.rb:8-19`
- ToolCall after-commit touch hook: `app/models/tool_call.rb:13-19`
- RubyLLM gem `to_llm` (read-only reference, not modified): `~/.frum/versions/4.0.2/lib/ruby/gems/4.0.0/gems/ruby_llm-1.14.1/lib/ruby_llm/active_record/chat_methods.rb:78-94`
- bin/inspect-chat (structural pairing analyzer): `bin/inspect-chat`
- Smoke log evidence: `tmp/local_todo_app_with_modifications.log`
