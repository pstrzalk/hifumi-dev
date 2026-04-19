---
date: 2026-04-19T00:00:00+02:00
researcher: Paweł Strzałkowski
git_commit: c985dfe21a396868b6b0b9418288cb26236c1ab2
branch: phase-2-step-4-tools-and-create-plan
repository: rails-app-generator
topic: "RubyLLM 1.14.1 usage audit against the ruby_llm skill — what's off-canon, what's defensible"
tags: [research, ruby_llm, rails, chat, tools, streaming, structured-output, agents]
status: complete
last_updated: 2026-04-19
last_updated_by: Paweł Strzałkowski
---

# Research: RubyLLM 1.14.1 usage audit against the ruby_llm skill

**Date**: 2026-04-19
**Researcher**: Paweł Strzałkowski
**Git Commit**: c985dfe (parent repo) / 9a4156e (skill subrepo)
**Branch**: phase-2-step-4-tools-and-create-plan
**Repository**: rails-app-generator

## Research Question

> "You have a skill for ruby_llm. We built this application without this skill. Research our codebase and see if there is anything we did wrong, or where there are better / more canonical solutions."

The user explicitly asked for critique — this document deliberately breaks the
default `/rpi:research_codebase` "document only, never critique" rule.

## Summary

The RubyLLM integration is **functionally correct and defensibly structured**.
There are no bugs or security issues. The codebase passes every core principle
in the skill (global config with `use_new_acts_as = true`, `acts_as_chat/
message/tool_call/model` on the right models, `params` DSL tools, `choice:
:required`, `halt`, tool-name auto-derivation, etc.).

But there are **seven places** where the code diverges from what the skill
recommends, the `ruby_llm:chat_ui` generator produces, or the `RubyLLM::Agent`
/ `RubyLLM::Schema` abstractions would give you. Rated by impact:

| # | Finding | Severity | Effort to fix |
| :--- | :--- | :--- | :--- |
| 1 | Streaming writes full `content` to DB per chunk + replaces whole partial per chunk | **Performance — high** on long responses | Medium |
| 2 | `CreatePlan::AdHocLLM` uses tool-call-as-structured-output instead of `RubyLLM::Schema` + `with_schema` | **Design — high** (simpler + portable + no `fetch_any` workaround) | Low |
| 3 | `ChatRespondJob` re-loads system prompt + re-attaches tools per call; a good candidate for `RubyLLM::Agent` | **Design — medium** (less code, idiomatic) | Medium |
| 4 | `chat.complete` used where the canonical chat_ui generator uses `chat.ask(content)` | **Convention — low** (defensible) | Low |
| 5 | `Message` uses custom `after_*_commit` broadcasts instead of `broadcasts_to` + `broadcast_append_chunk` | **Convention — low** | Low |
| 6 | `rescue StandardError` in `ChatRespondJob` doesn't distinguish `RubyLLM::Error` subclasses | **Robustness — low** | Low |
| 7 | Cosmetic: `def name = "..."`, `super()` in tool init, unused `Model` table | **Cosmetic** | Trivial |

The rest of this document walks each finding with file references and the
canonical shape from the skill.

---

## Finding 1 — Streaming: per-chunk full-partial replace + full-content DB write

**Where**: `app/jobs/chat_respond_job.rb:18-27`

```ruby
chat.complete do |chunk|
  delta = chunk.content.to_s
  next if delta.empty?

  assistant = latest_streaming_assistant(chat)
  next if assistant.nil?

  assistant.update_columns(content: assistant.content.to_s + delta)
  broadcast_replace(project, assistant)
end
```

**What happens**: every token fragment triggers (a) a DB write of the entire
accumulated content, and (b) a Turbo `broadcast_replace` that re-renders the
full `messages/message` partial and pushes it to every subscriber. For a
2 KB response arriving in 200 chunks, that's 200 full-partial renders and
~200 KB of DB writes (the last write is 2 KB; total is ~200 KB due to
cumulative writes).

**What the skill says** (`references/rails.md:141-162`, `references/streaming.md:36-50`):

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  acts_as_message
  broadcasts_to ->(msg) { "chat_#{msg.chat_id}" }, inserts_by: :append
  def broadcast_append_chunk(content)
    broadcast_append_to "chat_#{chat_id}",
      target: "message_#{id}_content",
      content: ERB::Util.html_escape(content.to_s)
  end
end

# app/jobs/chat_response_job.rb
chat.ask(user_content) do |chunk|
  next if chunk.content.nil? || chunk.content.empty?
  chat.messages.last.broadcast_append_chunk(chunk.content)
end
```

**Difference**:
- `broadcast_append_chunk` sends a `turbo-stream action="append"` carrying only
  the delta to a named target div (`message_<id>_content`). Browser appends
  text to that div — no full-partial re-render.
- RubyLLM's own `persist_message_completion` writes `content` to the DB **once**
  at the end of the stream (see skill's `rails.md:92-102` "Persistence flow" —
  step 3 updates the assistant row on success).

**Why the codebase does it differently**: persisting per chunk means partial
content survives a job crash. That's a legitimate trade-off, but the price is
high: O(N²) DB write volume on content length, and full-partial broadcasts add
render cost + Action Cable bandwidth.

**Canonical migration path** (if you accept the trade-off):
1. Change `ChatRespondJob` to use `chat.ask(user_content)` + `broadcast_append_chunk`.
2. Add a `target: "message_<id>_content"` div in `views/messages/_message.html.erb`.
3. Drop `update_columns` and the manual `broadcast_replace` loop.
4. Decide how to handle the "user wants their message persisted before the job
   runs" requirement — probably move user-message creation into the job (stops
   persisting on a dead queue).

---

## Finding 2 — `CreatePlan::AdHocLLM` forces a tool call instead of using `with_schema`

**Where**: `app/services/create_plan/ad_hoc_llm.rb:8-45`, plus the symbol/string
key workaround at lines 72-76.

```ruby
class EmitPlan < RubyLLM::Tool
  def name = "emit_plan"
  description "Emit the application-generation plan. Call this exactly once..."
  params do
    string :instruction_description, ...
    array :revisions, description: "..." do
      object do
        string :summary, ...
        string :prompt, ...
      end
    end
  end
  def execute(instruction_description:, revisions:)
    @captured = { instruction_description:, revisions: }
    halt({ ok: true })
  end
end

def self.invoke_llm(system:, user:)
  tool = EmitPlan.new
  chat = RubyLLM.chat(model: MODEL)
  chat.with_instructions(system)
  chat.with_tool(tool, choice: :required)
  chat.ask(user)
  tool
end

# RubyLLM normalises top-level tool args to symbols but leaves nested hashes
# with string keys (JSON.parse default). Look up under either.
def self.fetch_any(hash, key)
  hash.fetch(key) { hash.fetch(key.to_s) }
end
```

**What this is doing**: using a forced tool call as a structured-output
mechanism. Nothing is wrong — the model is forced to emit typed JSON, the tool
captures it, `halt` short-circuits the follow-up turn, and `fetch_any` patches
over the fact that RubyLLM symbolizes top-level tool args but leaves nested
hashes with string keys.

**What the skill says** (`references/structured-output.md:1-50, 152-159`):

> | Need | Use |
> | Typed JSON answer once | `with_schema` |
> | Model calls your code mid-conversation | tool |

```ruby
class PlanSchema < RubyLLM::Schema
  string :instruction_description, description: "One-sentence human description..."
  array :revisions, description: "Ordered list of 3 to 6 atomic revisions." do
    object do
      string :summary, description: "Git-commit-style one-liner..."
      string :prompt,  description: "Concrete, file-level instruction..."
    end
  end
end

chat = RubyLLM.chat(model: MODEL)
chat.with_instructions(SYSTEM_PROMPT)
response = chat.with_schema(PlanSchema).ask(user_prompt)
# response.content is a parsed Hash — no tool roundtrip, no fetch_any.
```

**Differences (all favor `with_schema`)**:
1. No extra tool-result roundtrip in the conversation.
2. `response.content` is a Hash — no `@captured` instance variable pattern.
3. No symbol/string key quirk — schema responses go through the same parser
   and return consistent key types (the `fetch_any` helper disappears).
4. Portable across providers (OpenAI structured outputs, Anthropic's JSON mode,
   Gemini's `responseSchema` — all unified behind `with_schema`).
5. Works with `RubyLLM::Schema` classes that can also live in `app/schemas/`
   and be regenerated by `bin/rails generate ruby_llm:schema Plan` — the
   empty `app/schemas/` folder is currently unused.
6. Half the code. The whole `CreatePlan::AdHocLLM` module collapses to a
   `RubyLLM.chat.with_instructions(...).with_schema(PlanSchema).ask(...)`.

**Why the codebase chose tools**: looking at the pattern, this was probably
written before the `RubyLLM::Schema` reference was consulted. It's a
mechanical translation away.

**Validation trade-off**: the current flow raises `InvalidResponse` from Ruby
land when fields are missing. With `with_schema` you get provider-side schema
enforcement (strict mode on OpenAI, JSON-mode on Anthropic) — missing fields
are far less likely, and when they occur you check `response.content.key?(...)`
the same way.

---

## Finding 3 — `ChatRespondJob` is a hand-rolled agent

**Where**: `app/jobs/chat_respond_job.rb:4-16`

```ruby
CHAT_SYSTEM_PROMPT = Rails.root.join("app/prompts/chat_system.md").read.freeze

def perform(message_id)
  user_message = Message.find(message_id)
  chat = user_message.chat
  project = chat.project

  chat.with_instructions(CHAT_SYSTEM_PROMPT, replace: true)
  chat.with_tools(
    StartGeneration.new(project: project),
    SuggestPrompts.new(project: project),
    replace: true
  )
  chat.complete do |chunk| ... end
end
```

Every job run re-reads the prompt, re-attaches tools, re-instantiates tools
with the project dependency. That's exactly what `RubyLLM::Agent` exists for.

**What the skill says** (`references/agents.md:81-100`):

```ruby
class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  inputs :project

  instructions { prompt('chat_system') }  # reads app/prompts/generator_agent/chat_system.txt.erb
  tools do
    [StartGeneration.new(project: project), SuggestPrompts.new(project: project)]
  end
end

# In controller:
record = GeneratorAgent.create!(project: project)  # creates + configures Chat
# In job:
GeneratorAgent.find(chat.id, project: project).ask(content) { |c| ... }
```

**Benefits**:
- System prompt colocated with the agent (ERB file auto-resolved by naming
  convention: `app/prompts/generator_agent/instructions.txt.erb`).
- Tools declared once on the class, instantiated with runtime inputs.
- The empty `app/agents/` folder (created by the install generator) would
  finally have something in it.
- On `.find(...)`, RubyLLM re-applies instructions as a runtime-only message
  so the system-row doesn't duplicate (skill's `rails.md:168-175`).

**Caveat**: the current `CHAT_SYSTEM_PROMPT` is a plain `.md` file, not ERB.
If you never need interpolation, `instructions { Rails.root.join(...).read }`
works fine; or rename to `.txt.erb` and use the auto-resolution.

---

## Finding 4 — `chat.complete` where the skill uses `chat.ask(content)`

**Where**: `app/jobs/chat_respond_job.rb:18` (uses `chat.complete`).

**What the skill says** (`references/rails.md:164`):

> Use `chat.ask(content) do |chunk| ... end` — not `chat.complete` — so the
> user message gets added and persisted before streaming begins.

**Why the codebase uses `complete`**: the user message is already persisted
in the controllers (`app/controllers/messages_controller.rb:14`,
`app/controllers/projects_controller.rb:17`) before the job is enqueued. So
`chat.complete` is calling the model with the already-saved conversation
state. That's correct.

**This isn't wrong — it's a deliberate architectural split**. The advantage
is the user sees their message in the UI instantly (via `Message#after_create_commit`)
even if the job queue is backed up. The disadvantage is split-brain
persistence (user message in controller, assistant message implicit in
`chat.complete`).

If Finding 1 is acted on (switch to canonical streaming), this also flips:
move user-message creation into the job and use `chat.ask(content)`. Otherwise
keep `chat.complete` — it matches how you're using it.

---

## Finding 5 — Custom Message broadcasts instead of `broadcasts_to`

**Where**: `app/models/message.rb:5-30`

The Message model uses:

```ruby
after_create_commit :broadcast_append_message   # broadcasts to chat.project
after_update_commit :broadcast_replace_message  # broadcasts to chat.project
```

And `ToolCall` re-triggers it via `touch_message`:

```ruby
# app/models/tool_call.rb:8-14
after_commit :touch_message
def touch_message
  message&.touch
end
```

**What the skill uses** (`references/rails.md:129-147`):

```ruby
broadcasts_to ->(msg) { "chat_#{msg.chat_id}" }, inserts_by: :append
def broadcast_append_chunk(content) ... end
```

**Differences**:
1. Stream scope: the codebase broadcasts to the **project** (`turbo_stream_from @project` in `views/projects/show.html.erb:2`), the skill uses **chat** (`chat_<id>`). Both work; project scope is fine if one Chat per Project is the invariant (it is — `Project has_one :chat`).
2. The `touch_message` hop on ToolCall exists because Rails' broadcast callbacks fire on the parent Message save *before* RubyLLM has persisted the tool_calls. So the first broadcast doesn't see `message.tool_calls.any?`, and the pill doesn't render. Touching after the ToolCall commits triggers a second replace. **This is a real timing issue the skill does not document.** Worth raising to the RubyLLM maintainers.

Not wrong, but two notes:
- Using `broadcasts_to` would save the manual `after_*_commit` methods.
- The `touch_message` workaround could be replaced by letting the ToolCall itself `broadcast_replace_to(chat.project, ...)` its parent message — the result is the same, one fewer DB write.

---

## Finding 6 — `rescue StandardError` swallows typed RubyLLM errors

**Where**: `app/jobs/chat_respond_job.rb:28-34`

```ruby
rescue StandardError => e
  # TODO(Step 6): typed error event + proper UX
  Rails.logger.error(e.full_message)
  target = latest_streaming_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
  target.update!(content: "Error: #{e.message}")
  broadcast_replace(project, target)
end
```

The TODO acknowledges this. Quick list of `RubyLLM::Error` subclasses worth
distinguishing (`references/errors.md:1-30`):

| Class | Should happen |
| :--- | :--- |
| `ContextLengthExceededError` | Summarize earlier messages, not "Error: ..." in the UI |
| `RateLimitError` | RubyLLM retries internally; if still raised, backoff + retry the job |
| `UnauthorizedError` | Operator problem — log loudly, don't show key-leak details to user |
| `ConfigurationError` | Startup-time problem — this should be impossible at job time; fail loud |
| `OverloadedError` (529) | Retryable — `retry_job wait: ...` |

Also: `chat.messages.create!(role: :assistant, content: "")` (line 31) creates
an assistant row outside of `chat.ask`/`chat.complete`'s persistence flow.
That's legal (empty content is allowed because `acts_as_message` does not
add a presence validator — see `references/rails.md:104-115`), but it is
unusual. Consider creating via `chat.add_message(role: :assistant, content: "")`
so the Chat object sees the row too.

---

## Finding 7 — Cosmetics

### 7a. Redundant `name` overrides

`app/tools/start_generation.rb:2`: `def name = "start_generation"`
`app/tools/suggest_prompts.rb:2`: `def name = "suggest_prompts"`
`app/services/create_plan/ad_hoc_llm.rb:9`: `def name = "emit_plan"`

**Skill** (`references/tools.md:34-44`): names auto-derive from class name —
`StartGeneration` → `:start_generation`, `SuggestPrompts` → `:suggest_prompts`,
`EmitPlan` → `:emit_plan`. The overrides are no-ops. Delete them.

### 7b. Unnecessary `super()` in tool initializers

`app/tools/start_generation.rb:15`, `app/tools/suggest_prompts.rb:12`:

```ruby
def initialize(project:)
  super()
  @project = project
end
```

`RubyLLM::Tool#initialize` takes no args and does nothing the subclass needs.
The skill example (`references/tools.md:130-147`) does not call `super`. The
call is harmless but noise.

### 7c. `Model` acts_as_model is present but `bin/rails ruby_llm:load_models` never ran

`app/models/model.rb:2` declares `acts_as_model`, the migration exists
(`db/migrate/20260418091919_create_models.rb`) — but the `models` table is
empty. The skill's `references/models.md:74-80`:

> `bin/rails ruby_llm:load_models` loads `models.json` into the `Model` table.

Either drop `acts_as_model` + the migration (YAGNI) or run the rake task.
Right now it's dead schema.

### 7d. OpenRouter routing relies on model-ID inference

`config/initializers/ruby_llm.rb:3`: `config.default_model = "anthropic/claude-haiku-4.5"`.

No `provider: :openrouter` or `assume_model_exists` anywhere. This works
because the `anthropic/...` prefix is an OpenRouter-registry convention —
RubyLLM's `models.json` has it under the openrouter provider. Fine, but
worth knowing: if the registry ever drops that entry you'll get
`ModelNotFoundError`. A two-line defensive patch:

```ruby
# Either pin it explicitly:
chat = RubyLLM.chat(model: MODEL, provider: :openrouter)
# Or document in a comment next to the default_model line.
```

---

## What the codebase got right (worth highlighting)

For balance — these are non-obvious good calls:

- **`halt({ ok: true })`** (`create_plan/ad_hoc_llm.rb:29`) — correct use of
  halt to skip a wasted follow-up turn. Skill `references/tools.md:209-219`.
- **`choice: :required`** (same file, line 42) — correct v1.13+ API. Skill
  `references/tools.md:153-173`.
- **`validates :description, presence: true` on `Instruction`** — not on
  `Message`. The skill explicitly warns against presence validators on
  `Message.content` (`references/rails.md:104-115`). The codebase respects
  this: `app/models/message.rb` has none.
- **`touch_message` on ToolCall** — real timing bug identified and worked
  around. See Finding 5.
- **`fetch_any` for mixed-key tool args** — real RubyLLM quirk documented in
  the comment at `ad_hoc_llm.rb:72-76`. Not in the skill. If you move to
  `with_schema` (Finding 2) this goes away; otherwise keep the helper.
- **`use_new_acts_as = true`** in initializer — skill recommends this
  (`references/setup.md:122-124`).

---

## Code References

### Current-state pointers (for anyone fixing any of the above)

- `config/initializers/ruby_llm.rb:1-7` — config, OpenRouter key, `use_new_acts_as`
- `app/models/chat.rb:1-5` — `acts_as_chat` + project belongs_to
- `app/models/message.rb:1-30` — `acts_as_message` + custom broadcasts + `visible_in_chat?`
- `app/models/tool_call.rb:1-15` — `acts_as_tool_call` + touch workaround
- `app/models/model.rb:1-3` — `acts_as_model` (dormant)
- `app/jobs/chat_respond_job.rb:1-50` — streaming + tool-attachment logic (Findings 1, 3, 4, 6)
- `app/tools/start_generation.rb:1-67` — tool using project DI + `CreatePlan` call + `instruction.requested` event
- `app/tools/suggest_prompts.rb:1-32` — tool with Turbo broadcast side effect
- `app/services/create_plan/ad_hoc_llm.rb:1-78` — forced tool-call-as-structured-output (Finding 2)
- `app/services/create_plan.rb:1-15` — swappable-implementation facade
- `app/controllers/messages_controller.rb:14-15` — user message persisted in controller
- `app/controllers/projects_controller.rb:17-18` — first message persisted in controller
- `app/prompts/chat_system.md` — system prompt (Finding 3 would move this to `app/prompts/generator_agent/instructions.txt.erb`)
- `app/prompts/create_plan_system.md` — system prompt for planner
- `app/schemas/` — empty (would hold `PlanSchema` if Finding 2 is actioned)
- `app/agents/` — empty (would hold `GeneratorAgent` if Finding 3 is actioned)

### Skill references used

- `SKILL.md` — index + core principles + version pin (1.14.1)
- `references/setup.md` — provider keys, defaults, `use_new_acts_as`
- `references/rails.md` — acts_as, persistence flow, streaming generator, `broadcast_append_chunk`, runtime instructions, "do NOT add content presence validation"
- `references/chat.md` — `ask` vs `complete`, instructions, streaming shape
- `references/tools.md` — params DSL, auto-derived names, `choice:`, `halt`, error-hash pattern
- `references/structured-output.md` — `RubyLLM::Schema`, when to use it vs tools vs `with_params`
- `references/streaming.md` — Turbo Streams pattern, out-of-order fix, tool-call phases
- `references/errors.md` — typed error hierarchy, retry policy
- `references/agents.md` — `RubyLLM::Agent`, `chat_model`, `inputs`, ERB prompt auto-resolution
- `references/models.md` — OpenRouter routing via model ID prefix, registry, `assume_model_exists`

---

## Architecture Documentation

### Current flow (as of c985dfe)

```
User types in UI
  ↓
MessagesController#create
  ↓ creates Message(role: user, content:) → after_create_commit broadcasts to project
  ↓ enqueues ChatRespondJob.perform_later(message.id)
  ↓
ChatRespondJob#perform
  ↓ loads CHAT_SYSTEM_PROMPT from disk (per call)
  ↓ chat.with_instructions(..., replace: true)
  ↓ chat.with_tools(StartGeneration.new(project:), SuggestPrompts.new(project:), replace: true)
  ↓ chat.complete do |chunk|
  ↓   update_columns(content: content + delta)
  ↓   broadcast_replace(full message partial)
  ↓ end
  ↓
When model calls StartGeneration:
  ↓ CreatePlan.call → CreatePlan::AdHocLLM.call
  ↓   builds user prompt from intent + clarifications
  ↓   new RubyLLM.chat(model: MODEL)
  ↓   with_instructions(CREATE_PLAN_SYSTEM_PROMPT)
  ↓   with_tool(EmitPlan.new, choice: :required)
  ↓   chat.ask(user_prompt) → model forced to call emit_plan
  ↓   EmitPlan#execute captures @captured, halt({ ok: true })
  ↓ StartGeneration wraps result in Instruction + Revision records
  ↓ instruments "instruction.requested" (future job listens)
```

### Canonical shape (what the skill + generators would produce)

```
User types in UI
  ↓
MessagesController#create (only enqueues the job with content string)
  ↓ ChatRespondJob.perform_later(chat.id, content)
  ↓
ChatRespondJob#perform  (or: GeneratorAgent.find(chat_id, project:).ask(content))
  ↓ chat.ask(content) do |chunk|
  ↓   chat.messages.last.broadcast_append_chunk(chunk.content)  # delta only
  ↓ end
  ↓
Structured-output call:
  ↓ chat.with_schema(PlanSchema).ask(user_prompt)
  ↓ response.content is a parsed Hash
```

---

## Historical Context

- `docs/03-plans/01-phase-2-poc-generator-app.md` — Phase 2 plan names the
  RubyLLM integration steps but predates the skill. It doesn't reference
  `RubyLLM::Agent` or `RubyLLM::Schema`.
- `thoughts/shared/research/2026-04-18/phase-2-step-4-research.md` — Step 4
  research that decided on the tool-call plan-emission pattern. The decision
  rationale there may be worth revisiting in light of Finding 2.
- `thoughts/shared/plans/2026-04-18/phase-2-step-4-tools-and-create-plan.md` —
  the plan that produced `CreatePlan::AdHocLLM`.

## Related Research

- `thoughts/shared/research/2026-04-18/phase-2-step-4-research.md`

## Open Questions

1. **Is persisting the user message in the controller (before the job runs) a
   deliberate UX guarantee or an accident?** If deliberate, Findings 1 + 4
   remain worth doing but the migration plan changes. If accidental, the
   canonical `chat.ask(content)` flow wins on every axis.

2. **Is there a planned use for `app/agents/` and `app/schemas/`?** They were
   created by the `ruby_llm:install` generator (implied by their presence) but
   are empty. Findings 2 and 3 would populate them.

3. **Should `Model` + `acts_as_model` stay?** The table is empty and nothing
   reads from it. Either `bin/rails ruby_llm:load_models` on deploy or drop
   both.

4. **Should the `touch_message`-on-ToolCall timing issue be reported upstream
   to RubyLLM?** The skill doesn't document it; a gem-level fix would remove
   the workaround here and help other users.

## Suggested next steps (in priority order)

1. Finding 2 (swap `AdHocLLM` to `with_schema`) — highest ROI, lowest risk.
2. Finding 1 (canonical streaming with `broadcast_append_chunk`) — biggest
   perf win if responses can get long.
3. Finding 3 (promote `ChatRespondJob` logic into a `GeneratorAgent`) —
   code quality + populates the empty `app/agents/` folder.
4. Finding 6 (typed error handling) — already TODO'd in the code.
5. Finding 7 (cosmetics) — batch with any of the above.
