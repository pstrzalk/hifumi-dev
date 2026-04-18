# Phase 2 Step 4 — Tools (`StartGeneration` + `SuggestPrompts`) + `CreatePlan` Service Implementation Plan

## Overview

Wire the first LLM-invoked actions into the chat: the assistant, after gathering intent, calls `StartGeneration(intent, clarifications)`, which synchronously delegates to a `CreatePlan` service. `CreatePlan::AdHocLLM` makes a second (internal) LLM call that translates plain-language intent into a structured plan, returning an array of revision specs. `StartGeneration` persists an `Instruction` and N `Revision` rows, then emits `ActiveSupport::Notifications.instrument("instruction.requested", ...)`. A separate `SuggestPrompts` tool lets the assistant surface clickable next-step suggestions in a dedicated frame below the chat.

No subscriber is wired in Step 4. `ExecuteInstructionJob` stays absent. The notification fires into the void — deliberately, so Step 5 can shape it from scratch without inheriting a stub.

## Current State Analysis

Shipped through `85ede91` (Step 3 closed):

- Chat baseline end-to-end: `ProjectsController#create` → `MessagesController#create` → `ChatRespondJob#perform` calls `chat.complete do |chunk| ... end` and streams assistant content via Turbo.
- Models: `Project`, `Chat` (`acts_as_chat`), `Message` (`acts_as_message`), `ToolCall` (`acts_as_tool_call`), `Instruction`, `Revision` — all green.
- RubyLLM pinned to `anthropic/claude-haiku-4.5` via OpenRouter (`config/initializers/ruby_llm.rb:1-7`), `use_new_acts_as = true`. No global tool registration, no default system prompt.
- `app/tools/`, `app/agents/`, `app/prompts/`, `app/schemas/` exist as empty `.gitkeep` placeholders. `app/services/` does not exist.
- No `ActiveSupport::Notifications.instrument` calls anywhere.
- `test/jobs/chat_respond_job_test.rb` has a `ChatCompleteStub` harness (`test/jobs/chat_respond_job_test.rb:82-103`) that aliases `Chat#complete`, creates the assistant row manually, and yields `OpenStruct` chunks. Re-used/extended in Phase 3.

Divergences between the main plan (`docs/03-plans/01-phase-2-poc-generator-app.md:210-308`) and schema on disk (per `thoughts/shared/research/2026-04-18/phase-2-step-4-research.md`): `Instruction.user_intent`, `Revision.prompt`, `Revision.started_at`, `Revision.finished_at`, `Revision.metrics` are all referenced but absent. Phase 1 reconciles.

## Desired End State

A user can:

1. Start a new project with description "simple todo list with Tailwind".
2. Exchange 0–2 turns with the assistant (clarifying questions).
3. Observe the assistant call `StartGeneration(intent:, clarifications:)` — visible only as a subtle "⚙ Starting generation…" indicator, not a raw tool-call bubble.
4. See an `Instruction` row (with `user_intent` = raw intent, `description` from `CreatePlan`, `phase: :implementing`) and N `Revision` rows (each with `prompt`, `summary`, `position`, `status: :pending`, `parent`) materialise in the DB.
5. See an `instruction.requested` notification fire (observable in logs via `ActiveSupport::Notifications.subscribe` from `bin/rails c`, no subscriber in production code).
6. Receive a final assistant message summarising what was started ("I started building. Here's what's happening…"), plus a `SuggestPrompts` rendering in a separate frame below the chat with clickable cards that prefill the message form.

Verification:

- `bin/rails test` green across models, controllers, jobs, services, tools.
- Manual walkthrough confirms: tool call is invisible-ish (pill only), no tool-result bubble clutter, suggestions frame renders and its cards prefill.
- `bin/rails c` + a one-off `ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| puts p }` captures the payload with `instruction_id:`.

### Key Discoveries:

**RubyLLM 1.14.1 — tool contract (spiked for this plan):**
- `Chat#with_tool` accepts both classes and instances — `tool.is_a?(Class) ? tool.new : tool` (chat.rb:54-61 in the installed gem). So `StartGeneration.new(project: project)` is valid; the library won't re-instantiate it.
- Tools must respond to: `name`, `description`, `parameters`, `params_schema`, `provider_params`, `call(args)`. `RubyLLM::Tool` provides these out of the box.
- `chat.complete(tools: [...])` is sugar for `with_tool` per element followed by `complete`.

**RubyLLM 1.14.1 — streaming + tools (spiked):**
- `on_new_message(&block)` fires when each assistant/tool message starts streaming (chat.rb:227 for streaming, 238 before tool execution).
- `on_end_message(&block)` fires after each message completes (chat.rb:164 and 245).
- `on_tool_call(&block)` / `on_tool_result(&block)` fire around tool execution (lines 239, 241).
- **One assistant turn can produce multiple Messages**: assistant(tool_calls) → tool(result) × N → assistant(final text). Step 3's `latest_assistant(chat)` helper targets the wrong row during the tool-execution window — Phase 3 replaces it with a callback-captured `@streaming_message` reference.
- The `chunk` block gets chunks for every streaming message in the turn (text chunks + tool-call deltas). RubyLLM handles row persistence itself via `StreamAccumulator`; our block is for live-broadcast observation.

**Tool-call / tool-result rendering rule (from Step 2 RubyLLM smoke, `docs/03-plans/01-phase-2-poc-generator-app.md:182`):**
- Assistant message with `tool_calls.any?` and empty content → render a subtle "⚙ …" pill, not an empty bubble.
- `role: "tool"` message → render nothing (hide from the UI; they carry internal state the user does not need to see).

**Decision recap (from the back-and-forth of 2026-04-18):**
- `Instruction.phase` enum keeps the granular `researching/planning/implementing/completed/failed/cancelled`. Phase 2 creates Instructions directly in `:implementing` because W1 (research) doesn't exist and `CreatePlan` runs synchronously inside `StartGeneration#execute`.
- `CreatePlan::AdHocLLM` uses Haiku 4.5 via OpenRouter. Prefers `response_format: json_schema` for deterministic parsing; falls back to a single-tool-use pattern if OpenRouter+Haiku doesn't support schema-coerced output (verified in Phase 2).
- Chat system prompt set via `chat.with_instructions(prompt, replace: true)` **per request** inside `ChatRespondJob#perform`. Content is static in Step 4; Step 6 will extend with dynamic context.
- Tool instances (not classes) passed to `chat.complete(tools: [...])` — `StartGeneration.new(project: project)`. Confirmed compatible with RubyLLM.
- Prompts live in `app/prompts/*.md` as versioned content loaded at boot.
- No subscriber for `instruction.requested` in Step 4 — just emit.
- `SuggestPrompts` results render in a dedicated `turbo_frame_tag "suggestions"` below the chat, not inline in a tool-result bubble.

## What We're NOT Doing

- **No subscriber for `instruction.requested`**, no `ExecuteInstructionJob`. Step 5 owns both.
- **No dynamic system-prompt context** (revision summaries, instruction status). Static prompt now; Step 6 extends.
- **No UI fallback button** ("force StartGeneration"). If Haiku flakes on tool-calling, add in Step 4.5; manual test in Phase 3 will tell us whether that risk is real.
- **No streaming of `CreatePlan::AdHocLLM`'s inner LLM call.** It's a single synchronous request; users wait (~5–15s per Haiku latency) behind a pill. Optimisation deferred.
- **No tool-call or tool-result rendering richness.** Just the minimum to hide noise: empty-assistant pill + hidden tool bubble.
- **No retries** on `CreatePlan` or tool execution failure. Failures bubble up as an error assistant message (`"Error: …"` path reused from Step 3).
- **No changes to `Project.workspace_path` derivation** — the `def workspace_path` method shipped in `f3010ed` stays.
- **No `Current.project`**. Step 3's rejection stands; instance-scoped tool.
- **No new fixtures for services or tools in `test/fixtures/`.** Service/tool tests build their own objects inline.

## Implementation Approach

Four atomic commits, each green on its own.

1. **Schema reconciliation.** Add missing columns, update fixtures, extend model tests. No behaviour change.
2. **`CreatePlan` service + `AdHocLLM`.** Pure service + internal LLM adapter. No chat wiring yet.
3. **`StartGeneration` tool + chat wiring + notification.** `ChatRespondJob` refactored to callback-based streaming target tracking; system prompt per request; tool instance injected; notification fires. View partials updated for graceful tool-call / hidden tool-result rendering.
4. **`SuggestPrompts` tool + suggestions frame.** Tool returns prompts; dedicated frame renders clickable cards; Stimulus `suggestions` controller from Step 3 reused.

---

## Phase 1: Schema reconciliation

### Commit
`phase 2 step 4.1: instruction + revision schema reconciliation`

### Overview

One migration adds `Instruction.user_intent:text`, and `Revision.prompt:text (null: false)`, `Revision.started_at:datetime`, `Revision.finished_at:datetime`, `Revision.metrics:jsonb`. Fixtures updated. Model tests extended for the new attributes' presence/validation.

### Changes Required:

#### 1. Migration
**File**: `db/migrate/YYYYMMDDHHMMSS_add_step4_columns_to_instructions_and_revisions.rb` (new)

```ruby
class AddStep4ColumnsToInstructionsAndRevisions < ActiveRecord::Migration[8.0]
  def change
    add_column :instructions, :user_intent, :text

    add_column :revisions, :prompt,       :text,     null: false, default: ""
    add_column :revisions, :started_at,   :datetime
    add_column :revisions, :finished_at,  :datetime
    add_column :revisions, :metrics,      :json,     default: {}, null: false
  end
end
```

Notes:
- `prompt` `null: false` with a transient `default: ""` so existing fixture rows (backfilled in-file below) don't break the migration on apply. Model validates presence on create going forward.
- `metrics` uses `:json` (SQLite-compatible); switches to `:jsonb` when we move off SQLite.

#### 2. Model updates
**File**: `app/models/instruction.rb`
**Changes**: no-op for `user_intent` (no validation — plan says raw audit capture, nil is acceptable during transition).

**File**: `app/models/revision.rb`
**Changes**: add `validates :prompt, presence: true`.

```ruby
validates :prompt, presence: true
```

#### 3. Fixtures
**File**: `test/fixtures/instructions.yml`
**Changes**: add `user_intent: "build a flower shop with inventory"` to `flowers_v1`.

**File**: `test/fixtures/revisions.yml`
**Changes**: add `prompt: "…"` to both `flowers_v1_step1` and `flowers_v1_step2`. Use plausible one-sentence prompts that satisfy `W2.3` invariants (concrete tasks, no "Claude"/"Anthropic" tokens, assume initialized Rails app).

#### 4. Model tests
**File**: `test/models/instruction_test.rb`
**Changes**: add test that `user_intent` is nullable (creation without it succeeds).

**File**: `test/models/revision_test.rb`
**Changes**: add test that `prompt` is required (create without it raises `ActiveRecord::RecordInvalid`).

### Success Criteria:

#### Automated Verification:
- [x] `bin/rails db:migrate` applies cleanly.
- [x] `bin/rails test test/models` green — existing 19 runs + 2 new tests = 21 runs, assertions grow accordingly.
- [x] `bin/rails db:schema:dump` picks up the new columns (check `db/schema.rb`).
- [x] `bin/rails test test/controllers test/jobs` still green (no incidental breakage).

#### Manual Verification:
- [x] Inspect `db/schema.rb`: `instructions.user_intent` present; `revisions` has `prompt`, `started_at`, `finished_at`, `metrics`.

**Implementation Note**: Pause for manual confirmation before Phase 2.

---

## Phase 2: `CreatePlan` service + `AdHocLLM` adapter

### Commit
`phase 2 step 4.2: create_plan service + ad_hoc_llm adapter`

### Overview

Add `app/services/create_plan.rb` with the dispatch module + `AdHocLLM` adapter. `AdHocLLM` owns a system prompt (the "secret sauce" per A7) stored in `app/prompts/create_plan_system.md`, calls Haiku 4.5 via a fresh `RubyLLM.chat` instance (not the user's chat), and returns `[{summary:, prompt:}, ...]`. No tool, no controller change — just the service + thorough unit tests with the LLM call stubbed at a seam.

### Changes Required:

#### 1. Prompt file
**File**: `app/prompts/create_plan_system.md` (new)
**Changes**: System prompt for the planner. Contains rules the chat LLM *doesn't* have — "Rails Way, 3-6 revisions, Tailwind, Hotwire, Devise only if auth requested, concrete tasks (not meta), no 'Claude'/'Anthropic' tokens unless intent explicitly requires Anthropic integration." Ends with an instruction to respond with a JSON array matching a schema of `[{summary: string, prompt: string}, ...]`, and a one-line `instruction_description` field for the commit-message-able human description.

Content sketch (real text written during implementation):

```markdown
You are a Rails application planner. Given a user's plain-language intent,
produce a short implementation plan as JSON.

Rules for the plan:
- 3 to 6 revisions.
- Each revision is one atomic, testable change ("add Product model with name/price", not "set up the shop").
- Assume the workspace is an already-initialized Rails 8 app with Tailwind + Hotwire + Devise gems available. Do NOT include `rails new` or gem installation steps.
- Prefer Rails Way: scaffolds, concerns, validations over custom abstractions.
- Never reference "Claude", "Anthropic", or any LLM provider unless the user explicitly asks for Anthropic API integration.
- Each revision's `prompt` is the full instruction passed to the implementer agent — concrete, file-level, verifiable.
- Each revision's `summary` is a git-commit-style one-liner.

Respond with a single JSON object matching this shape exactly:
{
  "instruction_description": "one-sentence human description of the whole plan",
  "revisions": [
    { "summary": "...", "prompt": "..." },
    ...
  ]
}
```

Loaded at boot via `Rails.root.join("app/prompts/create_plan_system.md").read.freeze`. Constant lives in `CreatePlan::AdHocLLM`.

#### 2. Service module
**File**: `app/services/create_plan.rb` (new — creates the `app/services/` directory)

```ruby
module CreatePlan
  class << self
    def call(intent:, clarifications: {}, context: {})
      implementation.call(intent: intent, clarifications: clarifications, context: context)
    end

    def implementation
      @implementation ||= AdHocLLM
    end

    attr_writer :implementation
  end

  Result = Struct.new(:instruction_description, :revisions, keyword_init: true)
end
```

#### 3. `AdHocLLM` adapter
**File**: `app/services/create_plan/ad_hoc_llm.rb` (new)

```ruby
module CreatePlan
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/create_plan_system.md").read.freeze
    MODEL = "anthropic/claude-haiku-4.5"

    class InvalidResponse < StandardError; end

    def self.call(intent:, clarifications:, context:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      raw = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt)
      parse(raw)
    end

    def self.invoke_llm(system:, user:)
      chat = RubyLLM.chat(model: MODEL)
      chat.with_instructions(system)
      chat.ask(user).content
    end

    def self.build_user_prompt(intent, clarifications, _context)
      lines = ["Intent: #{intent}"]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      lines.join("\n")
    end

    def self.parse(raw)
      json = JSON.parse(raw)
      revisions = Array(json["revisions"]).map do |r|
        { summary: r.fetch("summary"), prompt: r.fetch("prompt") }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?
      CreatePlan::Result.new(
        instruction_description: json.fetch("instruction_description"),
        revisions: revisions
      )
    rescue JSON::ParserError, KeyError => e
      raise InvalidResponse, "malformed plan response: #{e.message}"
    end
  end
end
```

Notes:
- `invoke_llm` is the stubbable seam for tests (single method, obvious signature). Do NOT stub `RubyLLM.chat` directly.
- **Shipped with tool-use pattern, not text+JSON-parse.** The plan's back-pocket "pivot to tool-use" was activated on the first manual run — Haiku wrapped its response in a ```` ```json ```` fence despite a strict system prompt. Rather than chase format quirks with regex, shipped an inner `EmitPlan < RubyLLM::Tool` with a nested `params` schema (`instruction_description: string`, `revisions: [{summary:, prompt:}]`). `invoke_llm` attaches it with `choice: :required`, runs `chat.ask`, returns the tool (whose `execute` captured the structured args and halted continuation). `call` reads `tool.captured` and builds the `Result`. No text parsing; malformed output is a RubyLLM-level error, not a parsing puzzle. Added `inflect.acronym "LLM"` in `config/initializers/inflections.rb` so Zeitwerk resolves `ad_hoc_llm.rb` → `AdHocLLM`.

#### 4. Service tests
**File**: `test/services/create_plan/ad_hoc_llm_test.rb` (new)

One test per branch:

- Delegates the LLM call (asserts `invoke_llm` receives expected system + user prompt for a given input).
- Happy path: stub returns valid JSON with 3 revisions → returns a `CreatePlan::Result` with 3 revisions and the expected `instruction_description`.
- Clarifications incorporated: user prompt includes clarifications lines when present; omitted when `{}`.
- Empty revisions array → raises `InvalidResponse`.
- Malformed JSON → raises `InvalidResponse`.
- Missing `instruction_description` key → raises `InvalidResponse`.
- Missing `summary` or `prompt` in a revision → raises `InvalidResponse`.
- LLM raises → propagates (no rescue at this layer).

Stubbing shape:

```ruby
class CreatePlan::AdHocLLMTest < ActiveSupport::TestCase
  def stub_llm(response)
    CreatePlan::AdHocLLM.stub :invoke_llm, ->(**) { response } do
      yield
    end
  end

  test "happy path with 3 revisions" do
    stub_llm(<<~JSON) do
      {
        "instruction_description": "Simple todo list with Tailwind",
        "revisions": [
          { "summary": "Add Task model", "prompt": "Generate a Task model..." },
          { "summary": "Add TasksController", "prompt": "..." },
          { "summary": "Add index view", "prompt": "..." }
        ]
      }
    JSON
      result = CreatePlan::AdHocLLM.call(intent: "todo list", clarifications: {}, context: {})
      assert_equal 3, result.revisions.size
      assert_equal "Simple todo list with Tailwind", result.instruction_description
    end
  end
  # ...
end
```

**File**: `test/services/create_plan_test.rb` (new)

- `CreatePlan.call` delegates to `CreatePlan.implementation` with the same args.
- `CreatePlan.implementation` defaults to `AdHocLLM`.
- `CreatePlan.implementation=` allows swap (sanity check for A6 extensibility).

### Success Criteria:

#### Automated Verification:
- [x] `bin/rails test test/services` green.
- [x] `bin/rails test` all green (no regressions).
- [x] `app/services/` and `app/services/create_plan/` autoload correctly (Zeitwerk doesn't complain on boot).
- [x] `app/prompts/create_plan_system.md` exists and is non-empty.

#### Manual Verification:
- [x] In `bin/rails c`: `CreatePlan.call(intent: "todo list with Tailwind", clarifications: {})` — real Haiku call — returns a `CreatePlan::Result` with 3–6 revisions. Run 3 times; confirm every run parses without raising `InvalidResponse`. Note wall-time per call for Step 7 budget.
- [x] Inspect one `result.revisions.first[:prompt]` — verify it reads as a concrete, file-level task that satisfies W2.3 invariants (no "Claude" token, no `rails new`, no meta).

**Implementation Note**: If 2/3 manual runs fail to parse, STOP and pivot to the tool-use fallback described above before moving to Phase 3.

---

## Phase 3: `StartGeneration` tool + chat wiring + `instruction.requested`

### Commit
`phase 2 step 4.3: start_generation tool + chat system prompt + notification`

### Overview

The meaty phase. Add:

1. `StartGeneration` tool class (instance-scoped: `StartGeneration.new(project: project)`).
2. Chat system prompt at `app/prompts/chat_system.md`, loaded once and set per-request via `chat.with_instructions(prompt, replace: true)`.
3. `ChatRespondJob` refactored to:
   - Accept tools: `chat.complete(tools: [StartGeneration.new(project: project)])`.
   - Track the streaming target via `on_new_message` callback instead of re-querying `latest_assistant`.
   - Handle the multi-message turn (assistant(tool_calls) → tool(result) → assistant(final)).
4. `_message.html.erb` updated: assistant with empty content + `tool_calls.any?` renders a subtle pill; `role: "tool"` renders nothing.
5. `instruction.requested` notification fires after persistence.

### Changes Required:

#### 1. Prompt file
**File**: `app/prompts/chat_system.md` (new)

Content sketch:

```markdown
You are an assistant helping the user describe a Rails web application they
want to build. Your job is to understand intent, not to design the plan.

Guidelines:
- Ask at most 2 clarifying questions. Prefer building with reasonable defaults
  over interrogating.
- When the user's intent is clear enough to start, call the `StartGeneration`
  tool. Pass `intent:` as a plain-language description of what they want
  (not a list of models, controllers, or tasks). Pass `clarifications:` as a
  hash of the specific answers you gathered.
- Do NOT generate an implementation plan yourself. Do NOT list models,
  controllers, or files. That's not your job — the backend handles it.
- After `StartGeneration` returns, summarise what you started in 1-2 sentences
  and then call `SuggestPrompts` with 3-5 natural next steps the user might
  want (e.g., "add user authentication", "add admin dashboard", "seed some
  demo data"). Short, plain-language, user-facing.
```

Loaded at boot in `ChatRespondJob`:

```ruby
CHAT_SYSTEM_PROMPT = Rails.root.join("app/prompts/chat_system.md").read.freeze
```

#### 2. `StartGeneration` tool
**File**: `app/tools/start_generation.rb` (new)

```ruby
class StartGeneration < RubyLLM::Tool
  description "Starts application generation. Call when the user has described what they want to build and you have any clarifications you need."
  param :intent,          type: :string, desc: "Plain-language description of what the user wants, e.g. 'flower shop with inventory and Stripe'"
  param :clarifications,  type: :object, desc: "Answers to clarifying questions, as key-value pairs. Empty object if none."

  def initialize(project:)
    super()
    @project = project
  end

  def execute(intent:, clarifications: {})
    result = CreatePlan.call(
      intent: intent,
      clarifications: clarifications,
      context: { project_id: @project.id }
    )

    instruction = @project.instructions.create!(
      user_intent: intent,
      description: result.instruction_description,
      phase: :implementing,
      anchor_message: @project.chat.messages.order(:id).last
    )

    result.revisions.each_with_index do |r, i|
      instruction.revisions.create!(
        project: @project,
        summary: r[:summary],
        prompt: r[:prompt],
        position: i,
        status: :pending,
        parent: i.zero? ? nil : instruction.revisions.order(:position).last
      )
    end

    ActiveSupport::Notifications.instrument(
      "instruction.requested",
      instruction_id: instruction.id
    )

    {
      instruction_id: instruction.id,
      revision_count: result.revisions.size,
      instruction_description: result.instruction_description
    }
  rescue CreatePlan::AdHocLLM::InvalidResponse => e
    { error: "Could not generate a plan: #{e.message}. Ask the user to rephrase." }
  end
end
```

Notes:
- `super()` in `initialize` — `RubyLLM::Tool.new` has its own initializer; must pass through.
- Instance variable `@project` — not `Current.project`.
- `anchor_message` uses `order(:id).last` (not `.last` which is unordered in some AR contexts on SQLite).
- `position: i` (0-indexed per existing Revision fixture convention — `flowers_v1_step1` is position 0).
- `InvalidResponse` caught → tool returns an error Hash. RubyLLM serialises the Hash as the tool-result message content; the LLM sees it and can apologise to the user. No notification fires on error.

#### 3. `ChatRespondJob` refactor
**File**: `app/jobs/chat_respond_job.rb`
**Changes**: System prompt set per-request; tools array passed; streaming target tracked via `on_new_message` instead of `latest_assistant`.

```ruby
class ChatRespondJob < ApplicationJob
  queue_as :default

  CHAT_SYSTEM_PROMPT = Rails.root.join("app/prompts/chat_system.md").read.freeze

  def perform(message_id)
    user_message = Message.find(message_id)
    chat = user_message.chat
    project = chat.project

    chat.with_instructions(CHAT_SYSTEM_PROMPT, replace: true)

    streaming_message = nil
    chat.on_new_message { |message| streaming_message = message }

    chat.complete(tools: [StartGeneration.new(project: project)]) do |chunk|
      delta = chunk.content.to_s
      next if delta.empty? || streaming_message.nil?

      streaming_message.update_columns(content: streaming_message.content.to_s + delta)
      broadcast_replace(project, streaming_message)
    end
  rescue StandardError => e
    # TODO(Step 6): typed error event + proper UX
    target = streaming_message || chat.messages.create!(role: :assistant, content: "")
    target.update!(content: "Error: #{e.message}")
    broadcast_replace(project, target)
  end

  private

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

Notes:
- `streaming_message` is a local closed over by both the `on_new_message` callback and the chunk block. Reassigned on each new message in the turn — the chunk block always targets the row the library is currently streaming into.
- For a tool-calling turn, `streaming_message` is first the assistant-with-tool_calls row (empty content, chunk block usually gets no deltas for this — tool-call fragments don't have `.content`), then tool-result rows (briefly), then the final assistant text row (main stream target).
- `.update_columns` still bypasses callbacks (avoid broadcast storms from `after_create_commit`).
- `broadcast_replace` unchanged from Step 3.
- `latest_assistant` helper **deleted**.

#### 4. Message partial — hide/pill branches
**File**: `app/views/messages/_message.html.erb`
**Changes**: three new branches.

```erb
<% if message.role == "tool" %>
  <%# Hide tool-result messages entirely. %>
  <% return %>
<% end %>

<div id="<%= dom_id(message) %>" class="flex <%= message.role == "user" ? "justify-end" : "justify-start" %>">
  <div class="max-w-[80%] rounded px-3 py-2 <%= message.role == "user" ? "bg-blue-100" : "bg-gray-100" %>">
    <div class="text-xs text-gray-500 mb-1"><%= message.role %></div>

    <% if message.role == "assistant" && message.content.to_s.strip.empty? && message.tool_calls.any? %>
      <div class="text-sm italic text-gray-600">
        <%= tool_call_pill_text(message) %>
      </div>
    <% else %>
      <div class="whitespace-pre-wrap"><%= message.content %></div>
    <% end %>
  </div>
</div>
```

**File**: `app/helpers/messages_helper.rb` (new)

```ruby
module MessagesHelper
  def tool_call_pill_text(message)
    names = message.tool_calls.map(&:name).uniq
    case names
    in ["StartGeneration"] then "⚙ Starting generation…"
    in ["SuggestPrompts"]  then "💡 Preparing suggestions…"
    else "⚙ Running: #{names.join(", ")}"
    end
  end
end
```

Notes:
- The `<% return %>` inside a partial is valid — ERB compiles to a method, and `return` exits early. Used deliberately so `broadcast_append_message` in `Message#after_create_commit` can still fire for tool rows without rendering anything; the broadcast append produces a zero-content stream frame, which Turbo Streams applies as a no-op on the DOM.
- Alternative considered and rejected: gate the broadcast at the model (`return if role == "tool"`). Rejected because it couples model to view decisions, and a future UI mode may want to show tool rows for debugging.

#### 5. Tool test
**File**: `test/tools/start_generation_test.rb` (new — creates `test/tools/` directory)

One test per branch:

- Given a valid `CreatePlan::Result` (stub `CreatePlan.call`), `execute(intent: "...", clarifications: {})` creates exactly one `Instruction` with `user_intent`, `description`, `phase: "implementing"`, and the correct `anchor_message`.
- Creates N `Revision` rows with correct `prompt`, `summary`, `position`, `status: "pending"`, chained via `parent`.
- First Revision has `parent: nil`; subsequent have `parent == previous`.
- Emits `instruction.requested` with `instruction_id:` — assert via `ActiveSupport::Notifications.subscribed`.
- Returns a Hash with `instruction_id`, `revision_count`, `instruction_description`.
- `CreatePlan::AdHocLLM::InvalidResponse` → tool returns error Hash; no Instruction persisted; no notification fired.
- `CreatePlan.call` raises other `StandardError` → propagates (tool does NOT rescue arbitrary errors — the job's rescue handles it).

Stub `CreatePlan.call` via `CreatePlan.stub(:call, ...)`.

#### 6. Job test updates
**File**: `test/jobs/chat_respond_job_test.rb`
**Changes**: 

- Existing `ChatCompleteStub` rewritten: instead of aliasing `Chat#complete` monolithically, stub accepts an optional `tool_calls_block` that, when the user message hits the stub, first invokes `on_new_message` with an assistant row (tool_calls populated via callable that exercises the real tool), then persists a tool-result row, then invokes `on_new_message` again with a final assistant row and yields text chunks.
- One test per branch:
  - (existing tests) No-tool happy path, multi-chunk, empty chunks, no chunks, rescue mid-stream, rescue immediate — all still green, unchanged test bodies.
  - New: asserts `chat.with_instructions` called exactly once per `perform` with `CHAT_SYSTEM_PROMPT` and `replace: true`. Spy via `Chat.class_eval` wrapping `with_instructions` to capture args.
  - New: asserts tools array passed to `chat.complete` includes a `StartGeneration` instance whose `@project == chat.project`.
  - New: tool-calling turn — stub simulates a tool call; assert `StartGeneration#execute` was invoked with the stubbed intent/clarifications; assert one `Instruction` created; assert `instruction.requested` notification fired; assert final assistant message has the summary content from the stub.
  - New: tool raises inside `execute` → `ChatRespondJob`'s rescue catches; assistant row (the final one, or a freshly-created one if none exists yet) content begins `"Error: "`.

Stub shape (illustrative):

```ruby
def stub_complete_with_tool(&tool_behaviour)
  # New stub simulates the tool-calling flow:
  # 1. calls chat.instance_variable_get(:@on_new_message).call(empty_assistant_with_tool_calls)
  # 2. invokes the tool instance with recorded args → persists a role: "tool" message
  # 3. calls on_new_message with a fresh assistant
  # 4. yields text chunks for the final assistant
  # Block receives (chat, tools) so the test can inspect what was passed.
end
```

Alternative to keeping the monkey-patch stub: use `Minitest::Mock` on `Chat#complete` directly for the new tests, keep the old `alias_method` pattern only for existing tests. Pick whichever reads cleaner during implementation.

#### 7. `broadcast_append_later_to` unchanged
`Message#broadcast_append_message` stays — Turbo broadcasts for tool-result rows produce no DOM output thanks to the partial's `<% return %>`. No model change needed.

### Success Criteria:

#### Automated Verification:
- [x] `bin/rails test` green: models + controllers + jobs + services + tools.
- [x] `bin/rails test test/tools/start_generation_test.rb` green, every branch covered.
- [x] `bin/rails test test/jobs/chat_respond_job_test.rb` green — existing 7 tests + new tests.
- [x] `app/prompts/chat_system.md` exists and is non-empty.
- [x] `app/tools/start_generation.rb` loads via Zeitwerk (boot succeeds).

#### Manual Verification:
- [x] Start `bin/dev`. Create a project with description "simple todo list with Tailwind".
- [x] Chat responds with 0–2 clarifying questions, then (without user typing another message prompting a plan) calls `StartGeneration`. Observe: no raw tool-call bubble; a "⚙ Starting generation…" pill appears briefly; final assistant message summarises what was started.
- [x] `Instruction.last` in `bin/rails c` shows `user_intent`, `description`, `phase: "implementing"`, 3+ revisions with `prompt` populated.
- [ ] Open `bin/rails c`, run `ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| puts p.inspect }`, trigger a new project in another terminal, confirm the payload hits stdout.
- [x] No `role: "tool"` bubbles visible in the chat UI.
- [ ] Break Haiku (temporarily point `OPENROUTER_API_KEY` at a dud) → observe `"Error: …"` message in chat, no orphaned Instruction in DB.

**Implementation Note**: Pause for manual confirmation before Phase 4. If Haiku flakes on calling `StartGeneration` reliably (>1 failure in 5 tries), open Step 4.5 for the UI fallback button before continuing.

### Phase 3 shipped notes (divergences from plan)

1. **`<% return %>` in partial → `<% unless message.role == "tool" %>` wrapper.** `return` inside an ERB partial is a hack that relies on ERB's compile-to-method detail. The wrapper is idiomatic.
2. **`chat.complete(tools: [...])` → `chat.with_tools(tool, replace: true)` then `chat.complete { }`.** RubyLLM 1.14.1 `Chat#complete(&)` takes only a block — no tools kwarg. The plan's "sugar" claim was wrong for this version. (Saved to memory as `project_ruby_llm_chat_api.md`.)
3. **Broadcast gated at the Message model** (`return unless %w[user assistant].include?(role)`). The plan rejected this; we enabled it because `chat.with_instructions` persists a `role: "system"` row each request, which would flood zero-content Turbo frames to the wire.
4. **`anchor_message` = latest user message**, not `chat.messages.last`. By the time `StartGeneration#execute` runs inside `handle_tool_calls`, RubyLLM's `persist_new_message` callback has already created an empty assistant row that will become the tool-result — so `.last` points at the wrong semantics. The latest user message has unambiguous meaning.
5. **No `on_new_message` callback to capture the streaming row.** RubyLLM 1.14.1 fires the `on_new_message` block with 0 args. Can't capture the message from it. Re-query `latest_streaming_assistant(chat)` on each chunk instead. (Saved to memory as `project_ruby_llm_message_lifecycle.md`.)
6. **Tool-call pill required additional wiring.** `tool_calls` are persisted AFTER `message.save!` — so `Message#after_update_commit` fires before they exist, and the partial's `message.tool_calls.any?` branch never runs. Fix: add `ToolCall#after_commit :touch_message` to trigger a second update_commit on the parent once the tool_call row exists. Re-broadcast then sees them. (Also in the message-lifecycle memory.)
7. **Rescue logs via `Rails.logger.error(e.full_message)`** — Ruby's standard full-formatted error message (class + message + backtrace). Universal, reusable in any future rescue.

---

## Phase 4: `SuggestPrompts` tool + suggestions frame

### Commit
`phase 2 step 4.4: suggest_prompts tool + suggestions frame`

### Overview

Second tool, lighter. `SuggestPrompts(prompts: [...])` returns the array; a controller-owned Turbo frame below the chat renders the latest suggestions as clickable cards that prefill the message form via the Step 3 Stimulus `suggestions` controller.

### Changes Required:

#### 1. `SuggestPrompts` tool
**File**: `app/tools/suggest_prompts.rb` (new)

```ruby
class SuggestPrompts < RubyLLM::Tool
  description "Suggests 3-5 short next-step prompts the user can click to continue. Call after StartGeneration returns, or when offering the user a direction to take."
  param :prompts, type: :array, desc: "Plain-language, short (<= 10 words), user-facing prompts."

  def initialize(project:)
    super()
    @project = project
  end

  def execute(prompts:)
    sanitized = Array(prompts).map(&:to_s).map(&:strip).reject(&:empty?).first(5)
    broadcast_suggestions(sanitized)
    { prompts: sanitized }
  end

  private

  def broadcast_suggestions(prompts)
    Turbo::StreamsChannel.broadcast_replace_to(
      @project,
      target: "suggestions",
      partial: "suggestions/frame",
      locals: { prompts: prompts }
    )
  end
end
```

Notes:
- Broadcast replaces a `#suggestions` Turbo frame sitting below the chat. This keeps the suggestions "sticky" across turns — each new `SuggestPrompts` call overwrites the frame; old suggestions vanish.
- `first(5)` guards against the LLM returning 10+ prompts.
- Persisted tool-result bubble (with `{ prompts: [...] }`) is still hidden by the partial's `<% return %>` rule from Phase 3 — users see only the frame.

#### 2. Suggestions frame partial
**File**: `app/views/suggestions/_frame.html.erb` (new)

```erb
<%= turbo_frame_tag "suggestions" do %>
  <% if prompts.present? %>
    <div class="mt-4 flex gap-2 flex-wrap" data-controller="suggestions">
      <% prompts.each do |prompt| %>
        <button type="button"
                class="px-3 py-1 rounded border text-sm hover:bg-gray-100"
                data-action="click->suggestions#prefillMessage"
                data-suggestions-value-param="<%= prompt %>">
          <%= prompt %>
        </button>
      <% end %>
    </div>
  <% end %>
<% end %>
```

#### 3. Show view — add empty frame at initial render
**File**: `app/views/projects/show.html.erb`
**Changes**: render an empty frame below the messages container so the first `broadcast_replace_to` has a target.

```erb
<%# after the messages div, before the message form %>
<%= render "suggestions/frame", prompts: [] %>
```

#### 4. Stimulus controller — add `prefillMessage` action
**File**: `app/javascript/controllers/suggestions_controller.js`
**Changes**: existing `prefill` action (from Step 3, on `/projects/new`) stays; add `prefillMessage` that targets the message-form input on `/projects/:id`.

```js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

  // Step 3: prefills the new-project textarea
  prefill(event) {
    if (!this.hasTextareaTarget) return
    this.textareaTarget.value = event.params.value
    this.textareaTarget.focus()
  }

  // Step 4: prefills the message form's content input by DOM id
  prefillMessage(event) {
    const input = document.getElementById("message_content_input")
    if (!input) return
    input.value = event.params.value
    input.focus()
  }
}
```

Add `id: "message_content_input"` to the message form's text field in `show.html.erb`.

#### 5. Hook `SuggestPrompts` into `ChatRespondJob`
**File**: `app/jobs/chat_respond_job.rb`
**Changes**: extend the `tools:` array.

```ruby
chat.complete(tools: [
  StartGeneration.new(project: project),
  SuggestPrompts.new(project: project)
]) do |chunk|
  ...
end
```

#### 6. Tool test
**File**: `test/tools/suggest_prompts_test.rb` (new)

One test per branch:

- Returns a `{ prompts: [...] }` Hash with the sanitised array.
- Strips whitespace and drops empty strings.
- Caps at 5 prompts.
- Broadcasts `turbo_stream.replace` to the project's stream, target `"suggestions"`, with the sanitised prompts in the locals — assert via `assert_broadcast_on` or capturing the rendered partial.
- Empty `prompts:` arg → empty-prompts broadcast (frame renders nothing; the `if prompts.present?` branch is exercised).

#### 7. Job test update
**File**: `test/jobs/chat_respond_job_test.rb`
**Changes**: one new test — asserts the `SuggestPrompts.new(project: project)` instance is included in the tools array passed to `chat.complete`.

### Success Criteria:

#### Automated Verification:
- [ ] `bin/rails test` all green.
- [ ] `bin/rails test test/tools/suggest_prompts_test.rb` green — every branch.
- [ ] `app/tools/suggest_prompts.rb` loads.

#### Manual Verification:
- [ ] Trigger a `StartGeneration` flow end-to-end. After the final assistant summary message, observe a row of 3–5 clickable cards below the chat.
- [ ] Click one — the message form's input is prefilled with that text; focus lands in the input.
- [ ] Submit the prefilled message → normal chat flow continues; new suggestions replace the old ones after the assistant's next turn.
- [ ] Refresh the page → the suggestions frame is empty on load (Phase 4 doesn't persist suggestions — Step 6/7 could, if we wanted).
- [ ] Two tabs on the same project: clicking in tab A prefills only tab A's input (local interaction); the frame replacement on the next LLM turn updates both tabs (broadcast).

**Implementation Note**: After Phase 4 manual verification, Step 4 is closed. Proceed to Step 5.

---

## Testing Strategy

### Unit tests:

- **Models** (`test/models/`): Phase 1 extends `instruction_test.rb` and `revision_test.rb` with `user_intent` / `prompt` branches. Existing tests untouched.
- **Services** (`test/services/`): `CreatePlan` delegation, `CreatePlan::AdHocLLM` happy path + every error branch (malformed JSON, empty revisions, missing keys, LLM raises).
- **Tools** (`test/tools/`): `StartGeneration` — persistence branches, error branches, notification. `SuggestPrompts` — sanitisation branches, broadcast.

### Job tests:

- `ChatRespondJob`: no-tool path (Step 3 tests preserved), tool-calling turn, system-prompt-always-set assertion, rescue paths.

### Integration tests:

- None in Step 4. End-to-end with real Claude CLI subprocess lives in Step 7.

### Manual testing walkthrough:

1. `CreatePlan.call(...)` in console, 3 runs, all parse.
2. `bin/dev`, create project, observe tool-calling flow end-to-end.
3. Break API key → observe `"Error: "` message, no orphan Instruction.
4. Verify notification via `ActiveSupport::Notifications.subscribe` in a separate console.
5. Click a suggestion card → input prefills.

### Token / API budget:

- Phase 2 manual check: 3 real Haiku calls (one per `CreatePlan` run).
- Phase 3 manual check: 2–3 real end-to-end chats, each ~2–4 chat turns + 1 `CreatePlan` call = ~8–12 Haiku calls.
- Phase 4 manual check: 2 end-to-end runs = ~4–6 Haiku calls.
- Total: ~20–25 Haiku API calls. Trivial against any subscription budget.

## Performance Considerations

- `CreatePlan::AdHocLLM` is synchronous inside `StartGeneration#execute`, which runs inside `ChatRespondJob#perform`. Haiku latency (~5–15s) means the user sees a "⚙ Starting generation…" pill for that window. Acceptable for PoC. If users complain (or Step 7 wall budget suffers), pivot to enqueue a separate `CreatePlanJob` and make `StartGeneration` return "queued" — but that fragments the tool-call UX and is explicitly out of scope.
- Tool-calling turns produce 3+ DB INSERTs (one empty assistant + N tool-result + one final assistant) plus all the `update_columns` chunk updates on the final assistant. SQLite WAL handles this fine for a single dev user; no concern for Phase 2.
- `broadcast_append_later_to` for tool-result messages produces zero-content stream frames (thanks to the partial's early-return). This is mild wasted bandwidth; if the WebSocket chatter is visible, gate the broadcast at the model level (`after_create_commit :broadcast_append_message, unless: -> { role == "tool" }`). Deferred.

## Migration Notes

One migration (Phase 1) adds four columns. Rollback is clean (`add_column` → `remove_column`). No data migration needed — the single `flowers_v1` fixture rows get backfilled via the fixture file update.

The `Revision.prompt` column uses `null: false, default: ""` so the migration applies without erroring on existing rows; the model-level `validates :prompt, presence: true` makes `""` invalid for new rows going forward. The transient default is the standard Rails pattern for adding a non-null column to a populated table.

## Open Risks (not blockers)

| Risk | Mitigation |
|------|------------|
| Haiku returns malformed JSON from `CreatePlan::AdHocLLM` more than rarely | Pivot to tool-use pattern (single `emit_plan` tool). 1-hour change. Back-pocket, applied only if manual testing shows flakiness. |
| Haiku fails to call `StartGeneration` reliably after 2-3 chat turns | Step 4.5: add a UI "Start generating" button that forces the tool call with the most recent user message as intent. Main plan risk table already notes this. |
| `on_new_message` callback fires on a message RubyLLM doesn't subsequently stream into | If `streaming_message` is reassigned but no chunks follow, the nil-guard in the chunk block handles it — nothing breaks, just no live broadcast for that row. |
| Multiple tool instances (`StartGeneration.new` + `SuggestPrompts.new`) per job share no state | By design. If Step 5 needs cross-tool state, inject via a shared context object — not via `Current`. |
| `<% return %>` inside an ERB partial surprises a future reader | Comment at the top of `_message.html.erb` explaining the tool-row suppression. |

## References

- Phase 2 plan (Step 4 section): `docs/03-plans/01-phase-2-poc-generator-app.md:210-308`
- Phase 2 architectural decisions (A6, A7): `docs/03-plans/01-phase-2-poc-generator-app.md:11-29`
- Step 3 plan (predecessor): `thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md`
- Step 4 research: `thoughts/shared/research/2026-04-18/phase-2-step-4-research.md`
- W2.3 agent prompt invariants: `docs/02-architecture/01-workflows-and-decisions.md:125-135`
- Step 2 RubyLLM smoke findings (tool-call persistence, parallel tools): `docs/03-plans/01-phase-2-poc-generator-app.md:176-182`
- Spike workflow prompt shape (`build_prompt`): `spikes/roast/revision_workflow.rb:84-116`
- Step 3 streaming implementation (replaced in Phase 3): `app/jobs/chat_respond_job.rb:1-38`
- Step 3 test stub pattern (extended in Phase 3): `test/jobs/chat_respond_job_test.rb:82-103`
- Step 3 broadcast wiring: `app/models/message.rb:9-14`
- RubyLLM 1.14.1 tool + streaming contract (from this plan's spike): `Chat#with_tool` accepts classes or instances; `on_new_message` / `on_end_message` / `on_tool_call` / `on_tool_result` fire per message during tool-calling turns.
