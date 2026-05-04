---
date: 2026-05-04
author: Paweł Strzałkowski
branch: randomized-design-systems
status: ready-for-implementation
related_research: thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md
related_ideas: docs/09-ideas/02-deferred-request-handling.md
---

# Chat-agent: design-tweak rebootstrap, premature "Done!", deferred follow-up

## Overview

Three chat-agent bugs surfaced during the manual end-to-end smoke of the templates plan:

- **Bug A — design-tweak rebootstrap.** A one-line tweak ("make the primary color teal") sent after a completed build re-runs `start_generation`, rebuilding the entire app from scratch (5-10 minutes, dollars in tokens, schema drift breaking the running preview).
- **Bug B — premature "Done!" reply.** The LLM streams "Done! Updated…" into the assistant message body within ~13 s of the user's request, while a multi-minute generation has only just been queued.
- **Bug C — deferred follow-up dropped on the floor.** Mid-build user messages ("make the banner green") get a polite "I'll handle it once finished" reply but are never resumed.

This plan replaces the single-tool surface (`start_generation`) with a mutual-exclusion two-tool design (`create_application` for greenfield, `modify_application` for tweaks), gates them on `Project#workspace_initialized?`, introduces a confirmation-first prompt rule (no `*_application` tool call without an immediately preceding user confirmation), moves the "🌀 Building…" narration from the LLM to a system-emitted message, and auto-fires a recap turn after every `instruction.completed` so mid-build messages get surfaced for explicit user confirmation.

The DB lifecycle (`Instruction`, `Revision`, all events, `ExecuteInstructionJob`, the Roast `revision_workflow`) is untouched. All changes are in the chat-agent layer and the planner services that feed it.

## Backstory

Source: `thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md` and the manual smoke of Project #9 ("children's storybook") on 2026-05-04, captured in `tmp/local_test_story_garden.log`.

### Bug A — `start_generation` is the only hammer

`StartGeneration#execute` creates a fresh `Instruction(phase: :implementing)` regardless of whether the project already has completed instructions. The chat agent's system prompt has only two states ("running" / "not running") and steers via `Project#current_state_prompt`. A design tweak after a completed build looks identical to a fresh project — there is no third path "the project already exists; this looks like a tweak; do something smaller."

Concrete trace:
- 12:48 — Original instruction #9 created via `start_generation`. 6 revisions implemented the kids template.
- 13:03:59 — Instruction #9 transitions to `completed` (`tmp/local_test_story_garden.log:6762`).
- 13:17:02 — User types "make the make the primary color teal" (`:7185`).
- 13:17:04 — `start_generation` tool call args persisted with the FULL original intent + "Primary color is teal." appended (`:7431`).
- 13:17:14 — New instruction created with kids-themed teal description, project_id=9, phase=implementing (`:7568`).
- Roast `[W2.1]` headers for revisions #47-#52 appear at log lines 1010, 2653, 3437, 3873, 4417, 5439 — six full revisions, full app re-implementation.

Schema-drift collateral: original revision #41 generated `rails generate scaffold Story title:string content:text average_rating:float rating_count:integer`. Rebuild revision #47 generated a different Story scaffold with `ratings aggregation` semantics. Restarting the preview between the two states surfaced `missing attribute 'rating_count' for Story` in the running container.

### Bug B — Premature "Done!" reply

`app/prompts/generator_agent/instructions.txt.erb:7` says: *"After `start_generation` returns, summarise what you started in 1-2 sentences"*. The model interprets this loosely and produces past-tense completion language. Streamed and persisted as the assistant message body before any code has been generated.

`Project#current_state_prompt` (`app/models/project.rb:45-54`) does have anti-claim guidance — but only in the "running" branch. When `start_generation` succeeds, the system prompt for that turn was the "no generation running" branch, so no anti-claim language was active.

Concrete trace:
- 13:17:02.655856 — User message persisted (`:7185`).
- 13:17:04.660892 — `start_generation` tool call written (`:7431`).
- 13:17:15.981449 — Streaming finishes: assistant content = `"Done! Updated the app with a beautiful teal color scheme throughout the interface. Everything should feel cohesive and delightful now."` (`:7967`).
- Time delta: 13.3 s between user message and final assistant content. A real revision takes 30-90 s for codegen alone; the 6-revision instruction took 5-10 min. The "Done!" cannot be referencing actual completion.

### Bug C — Deferred follow-up dropped without persistence

While an instruction is non-terminal, `current_state_prompt` injects a system-prompt line saying "Do NOT call `start_generation` now" + "Do NOT claim any new work has been done". The agent obediently emits a plain-text deferral. There is no tool, queue, or persistence path to capture the user's pending request. When the build finishes, nothing resumes it.

Concrete trace:
- 13:19:08 — User types "make to top banner green, not yellow" (`:8741`, message id 107 at `:8749`).
- The rebuild instruction (created 13:17:14) was still in `implementing`. `current_state_prompt` returned the "CURRENTLY RUNNING" branch.
- The `ChatRespondJob` that processed message 107 produced an assistant reply with **no `tool_calls`** — only plain text in the deferral language.
- 13:31:30 — Rebuild instruction completes (`:13547`). No subsequent `start_generation` tool call references "banner green". Final state: teal applied, banner remains yellow.

Existing analysis of Bug C plus four candidate solutions lives in `docs/09-ideas/02-deferred-request-handling.md` (written 2026-04-22 during Phase 2 Step 6 manual verification, deferred at the time).

## Naming decisions

Settled in interactive planning:

| Layer | Foundation/first-build | Modification |
|---|---|---|
| Tool name (LLM-facing) | `create_application` | `modify_application` |
| Tool class | `CreateApplication < RubyLLM::Tool` | `ModifyApplication < RubyLLM::Tool` |
| Tool file | `app/tools/create_application.rb` | `app/tools/modify_application.rb` |
| Planner module | `PlanApplicationCreation` | `PlanApplicationModification` |
| Planner adapter | `PlanApplicationCreation::AdHocLLM` | `PlanApplicationModification::AdHocLLM` |
| Planner file | `app/services/plan_application_creation.rb` | `app/services/plan_application_modification.rb` |
| Planner system prompt | `app/prompts/plan_application_creation_system.md` | `app/prompts/plan_application_modification_system.md` |
| Result struct | `PlanApplicationCreation::Result` | `PlanApplicationModification::Result` (duplicate of above; 2 lines) |
| Schema | shared `PlanSchema`, unchanged | same |

Rationale:
- **`create_application` / `modify_application`** — imperative, intent-revealing. "Application" is the concrete artifact. The LLM has zero translation work between user intent ("user wants to modify the application") and tool name.
- **`PlanApplicationCreation` / `PlanApplicationModification`** — verb-led ("Plan…"). The verb correctly names what the service does (it plans), and the noun phrase precisely describes what's being planned for. Sidesteps the awkwardness of `ModifyApplicationPlan` (which would parse as "modify the application plan" — but the planner doesn't modify, it creates a plan).
- **Untouched DB models** — `Instruction`, `Revision`, all events, `ExecuteInstructionJob`. Renames there would cost dozens of files for cosmetic gain.

## Architectural decisions

### D1 — Mutual-exclusion tool surface gated on `Project#workspace_initialized?`

The chat agent only ever sees ONE of the two mutation tools per turn:
- `workspace_initialized? == false` → tools = `[CreateApplication, SuggestPrompts]`
- `workspace_initialized? == true` → tools = `[ModifyApplication, SuggestPrompts]`

`workspace_initialized?` (already exists at `app/models/project.rb:38-40`) checks for a `Gemfile` in the project's workspace path. This is the right signal because:
- It tracks the actual structural state of the repo (does a Rails app exist on disk to revise against?).
- Self-healing for partial bootstraps: if the first `create_application` crashes before Rails is laid down, the next user message correctly routes back to `create_application`.
- Independent of in-progress state (`current_state_prompt` still owns "is something running right now").

### D2 — Confirmation-first flow

**Expensive operations require explicit user confirmation. No exceptions.** Every `create_application`/`modify_application` tool call must be the immediate consequence of a user message that confirms.

The chat-agent prompt is updated to:
1. Summarise the user's intent and ASK ("ready to start?") *before* calling `create_application`/`modify_application`.
2. Only call the mutation tool after explicit confirmation in the next user turn.
3. During an in-progress build, chat normally — no tool fires.

The auto-recap turn (D4) does NOT bypass this. The recap produces text only; the user's next message is what triggers the tool call.

### D3 — System-emitted starting message; LLM stops post-tool narration

`instruction.requested` gains a new subscriber that posts an assistant message: `"🌀 Building: <instruction.description>"`. Symmetric to the existing `instruction.completed` subscriber that posts `"✅ Generation finished."`.

The agent prompt is updated: *"After `create_application`/`modify_application` returns, do NOT write text. Only call `suggest_prompts` and stop."* The LLM no longer narrates around mutation tool calls. `Message#visible_in_chat?` (`app/models/message.rb:8-11`) already hides empty-content assistant messages with no `tool_calls`, so a tool-only assistant turn renders cleanly.

### D4 — Auto-recap on `instruction.completed`

A new subscriber on `instruction.completed` always enqueues a follow-up `ChatRespondJob` with a synthetic system nudge that drives the LLM to:
- Recap any pending mid-build user messages.
- Ask the user what to do next.
- **NOT** call any tool.

The synthetic nudge is persisted as a `Message(role: :user, system_injected: true)` so the existing RubyLLM message-loop sees it as the next user turn. A new `system_injected` boolean column on `messages` lets the UI hide it from rendering.

The LLM's output naturally adapts:
- Pending messages exist → "While I was working you asked for: add logo, change banner to green, then scratch the banner. Should I add the logo only?"
- No pending → "Build finished. Let me know what to change next!"

The user reads the recap and replies in their own words. The LLM's next turn (driven by the regular `ChatRespondJob` on the user's reply) re-enters the confirmation flow and ultimately fires `modify_application` on confirmation.

## Current state analysis

`CreatePlan` (`app/services/create_plan.rb`) is a thin façade with swappable `implementation` (default: `AdHocLLM`, swap to `PlanFixtures` in tests). One production call site: `StartGeneration#execute`.

`StartGeneration` (`app/tools/start_generation.rb:1-74`) is the sole "do work" tool. It:
1. Refuses with an error hash if `instructions.where.not(phase: %w[completed failed cancelled]).exists?` (`:20-24`).
2. Calls `CreatePlan.call(intent:, clarifications:, context:, openrouter_api_key:)`.
3. Transactionally persists `Instruction(phase: :implementing)` + N `Revision` rows chained by `parent`.
4. Instruments `instruction.requested`.

`GeneratorAgent` (`app/agents/generator_agent.rb:1-12`) binds two tools (`StartGeneration`, `SuggestPrompts`) and loads instructions from `app/prompts/generator_agent/instructions.txt.erb` with `current_state` interpolated.

`Project#current_state_prompt` (`app/models/project.rb:45-54`) returns one of two strings depending on whether any non-terminal instruction exists.

`config/initializers/event_subscribers.rb` wires:
- `instruction.requested` → `ExecuteInstructionJob.perform_later` + broadcast pending revisions list + `StopPreviewJob.perform_later`.
- `instruction.completed` → assistant message "✅ Generation finished." + clear active_revisions broadcast.
- `instruction.failed` → assistant message naming the failing revision + clear active_revisions broadcast.
- `revision.started/completed/failed` → broadcast revision card replace.

`Message` (`app/models/message.rb`) uses `acts_as_message` from RubyLLM. Visibility helper `visible_in_chat?` returns true for any user message and for assistant messages with non-empty content OR `tool_calls.any?`.

## Desired end state

After this plan:
- `workspace_initialized? == true` projects route every chat-agent mutation to `modify_application`. There are zero "rebuild from scratch" code paths. Verified by integration test that drives a tweak through the full flow and asserts only ONE new Instruction with ONE Revision (or 1-6 for a "start over" tweak — but never re-running the original 6 of the foundation).
- The string `"Done!"` (or any past-tense completion language) never appears in an assistant `Message#content` body during the seconds following a `create_application`/`modify_application` tool call. The only "build started" indicator is the system-emitted `"🌀 Building: ..."` message persisted by the new `instruction.requested` subscriber.
- After every `instruction.completed`, the chat shows `"✅ Generation finished."` followed by an LLM-generated recap+question. Mid-build user messages are quoted back to the user with a "should I proceed?" ask. The LLM never auto-fires `modify_application` in this turn.
- The chat-agent prompt explicitly forbids tool calls during in-progress builds AND requires user confirmation before calling `create_application`/`modify_application` even on a fresh project.

### Key discoveries

- The "running vs not running" steering signal in `current_state_prompt` is not the right discriminator for "fresh build vs tweak." `workspace_initialized?` is. The two signals are orthogonal: tool-surface visibility ↔ workspace state; whether-callable ↔ in-progress state.
- `RubyLLM::Tool` already supports per-instance `project:` injection (`SuggestPrompts.new(project:)`). The dual-tool surface fits the existing pattern with no framework changes.
- `Message#visible_in_chat?` already filters empty-bodied assistant messages — Phase 7's "LLM stops post-tool narration" doesn't need extra view filtering for the empty-body case.
- `Instruction#anchor_message` (the user message that triggered the build) gives an exact cutoff for "messages sent during this build" detection: `chat.messages.where(role: :user).where("id > ?", instruction.anchor_message_id)`.
- The existing test pattern uses singleton-method-swap for stubbing (`CreatePlan.define_singleton_method(:call, ...)`) per `test/tools/start_generation_test.rb:20-28`. New planner/tool tests follow this exact pattern.

## What we're NOT doing

Out of scope for this plan:

- **Renaming `Instruction`/`Revision` DB models.** Cosmetic; would touch dozens of files including the Roast workflow.
- **Workspace-state-aware modification planner.** `PlanApplicationModification` will receive the same `intent + clarifications + context: {project_id}` arg surface as `PlanApplicationCreation`. Future work could surface picked-template `frontend.md`, model list, etc., to the planner — out of scope here.
- **Preview-restart-during-rebuild gate.** Once Bug A is fixed, the schema-drift collateral that crashed the running preview disappears. The latent issue (user manually restarts preview during build, sees stale running container) is a UI affordance question (disable button while implementing? rate-limit?) for a separate plan.
- **Prompt-injection moderation on user messages.** Tracked separately under `docs/09-ideas/04-…` (or wherever the deferred research track lives).
- **Refactoring `app/services/` away from the service-object directory layout.** Existing code lives there; we match convention. `feedback_no_service_objects.md` applies to greenfield, not to extending an existing pattern.

## Implementation approach

Nine phases, each one atomic commit. Each phase leaves the codebase green (full test suite passes). Bugs are fixed in this order:

1. Phases 1-2 — mechanical renames, no behavior change.
2. Phases 3-4 — additive new code (planner + tool), not yet wired.
3. **Phase 5** — wires `ModifyApplication` into `GeneratorAgent` based on `workspace_initialized?`. **Bug A fix lands here.**
4. Phase 6 — confirmation-first prompt update.
5. **Phase 7** — system-emitted starting message + LLM stops post-tool text. **Bug B fix lands here.**
6. **Phase 8** — auto-recap subscriber. **Bug C fix lands here.**
7. Phase 9 — end-to-end integration test for the full design-tweak flow.

After each phase: pause for manual confirmation that automated verification + manual smoke pass before proceeding.

---

## Phase 1 — Rename `CreatePlan` → `PlanApplicationCreation`

### Commit
`chat-agent: rename CreatePlan to PlanApplicationCreation`

### Overview
Mechanical rename. No behavior change. The existing planner becomes the foundation/first-build planner; Phase 3 will add the modification planner alongside it.

### Changes Required

#### 1. Rename module + file
**Move**: `app/services/create_plan.rb` → `app/services/plan_application_creation.rb`
**Move**: `app/services/create_plan/` → `app/services/plan_application_creation/`
**Move**: `app/services/create_plan/ad_hoc_llm.rb` → `app/services/plan_application_creation/ad_hoc_llm.rb`

In each moved file, replace `module CreatePlan` → `module PlanApplicationCreation`. The internal class names (`AdHocLLM`, `Result`, `InvalidResponse`) stay the same.

#### 2. Rename system-prompt file
**Move**: `app/prompts/create_plan_system.md` → `app/prompts/plan_application_creation_system.md`

In `app/services/plan_application_creation/ad_hoc_llm.rb`, update the path:
```ruby
SYSTEM_PROMPT = Rails.root.join("app/prompts/plan_application_creation_system.md").read.freeze
```

The system-prompt content itself is unchanged in this phase. The "3 to 6 revisions" rule, root-route mounting, nav-menu rule, all stay.

#### 3. Update the single production call site
**File**: `app/tools/start_generation.rb`
**Changes**:
```ruby
# Line 26 — rename module
result = PlanApplicationCreation.call(
  intent: intent,
  clarifications: clarifications,
  context: { project_id: @project.id },
  openrouter_api_key: @project.user.profile.openrouter_api_key
)
# ...
# Line 65 — rename error class
rescue PlanApplicationCreation::AdHocLLM::InvalidResponse => e
```

#### 4. Rename test files + update references
**Move**: `test/services/create_plan_test.rb` → `test/services/plan_application_creation_test.rb`
**Move**: `test/services/create_plan/ad_hoc_llm_test.rb` → `test/services/plan_application_creation/ad_hoc_llm_test.rb`
**Move**: `test/fixtures/files/create_plan/` → `test/fixtures/files/plan_application_creation/`

In `test/services/plan_application_creation_test.rb`:
- Class `CreatePlanTest` → `PlanApplicationCreationTest`
- All references `CreatePlan` → `PlanApplicationCreation`

In `test/services/plan_application_creation/ad_hoc_llm_test.rb`:
- Class `CreatePlan::AdHocLLMTest` → `PlanApplicationCreation::AdHocLLMTest`
- All references `CreatePlan::AdHocLLM` → `PlanApplicationCreation::AdHocLLM`
- `file_fixture("create_plan/...")` → `file_fixture("plan_application_creation/...")`

#### 5. Update remaining references
**File**: `test/fixtures/plans/todo_list.rb`
```ruby
PlanApplicationCreation::Result.new(...)  # was: CreatePlan::Result
```

**File**: `test/integration/generate_todo_list_test.rb`
```ruby
@original_create_plan = PlanApplicationCreation.implementation
PlanApplicationCreation.implementation = fake_plan_returning(PlanFixtures.todo_list)
# ...
PlanApplicationCreation.implementation = @original_create_plan if @original_create_plan
```

**File**: `test/tools/start_generation_test.rb`
- `@plan = PlanApplicationCreation::Result.new(...)`
- `def stub_create_plan(result_or_proc)` — body uses `PlanApplicationCreation.method(:call)` and `PlanApplicationCreation.define_singleton_method(:call, original)`
- Test "on CreatePlan InvalidResponse" — rename to "on PlanApplicationCreation InvalidResponse"; raise `PlanApplicationCreation::AdHocLLM::InvalidResponse`
- Test "on unexpected error from CreatePlan" — rename to "on unexpected error from PlanApplicationCreation"

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` — all green (9 pre-existing preview_manager failures unrelated to Phase 1; 20 targeted tests pass)
- [x] `grep -r "CreatePlan" app/ test/ config/ lib/ bin/` returns no matches (sanity check after rename)
- [x] `grep -r "PlanApplicationCreation" app/ test/` returns matches in the renamed files
- [x] No file at the old paths: `test ! -e app/services/create_plan.rb && test ! -e app/prompts/create_plan_system.md`

#### Manual Verification:
- [x] `bin/generate full <intent>` smoke (uses `PlanFixtures.todo_list`) — verified via `bin/rails runner` exercising the same code path: PlanFixtures.todo_list + stubbed PlanApplicationCreation → StartGeneration#execute returns {instruction_id, revision_count: 3, instruction_description}; instruction persisted with phase=implementing and 3 revisions
- [x] Confirm `app/services/plan_application_creation/ad_hoc_llm.rb` boots without errors at Rails startup — `bin/rails runner` resolves PlanApplicationCreation, ::AdHocLLM, and SYSTEM_PROMPT successfully

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 2 — Rename tool: `start_generation` → `create_application`

### Commit
`chat-agent: rename start_generation tool to create_application`

### Overview
Rename the single existing chat tool. Tool-name-as-LLM-identifier changes (`start_generation` → `create_application`). Class rename (`StartGeneration` → `CreateApplication`). Behavior is unchanged.

### Changes Required

#### 1. Rename tool file + class
**Move**: `app/tools/start_generation.rb` → `app/tools/create_application.rb`

In the moved file:
```ruby
class CreateApplication < RubyLLM::Tool
  def name = "create_application"
  description "Starts the first-time generation of the application from the user's intent. " \
              "Call this only when the project has no application yet (workspace is empty). " \
              "The user must have explicitly confirmed they're ready to start before you call this."

  # params block, initialize, execute, anchor_message — unchanged
end
```

The description is reworded to reflect the new mutual-exclusion shape and the confirmation-first rule. The `params do ... end` block (intent + clarifications) is unchanged.

#### 2. Update GeneratorAgent
**File**: `app/agents/generator_agent.rb`
```ruby
tools do
  [
    CreateApplication.new(project: chat.project),
    SuggestPrompts.new(project: chat.project)
  ]
end
```

(Phase 5 will further modify this block to gate on `workspace_initialized?`.)

#### 3. Update agent prompt's tool reference
**File**: `app/prompts/generator_agent/instructions.txt.erb`
- Replace every occurrence of `` `start_generation` `` with `` `create_application` ``
- Behavior rules in the prompt are unchanged in this phase. Phase 6 rewrites the prompt for confirmation-first flow.

#### 4. Rename test file + class
**Move**: `test/tools/start_generation_test.rb` → `test/tools/create_application_test.rb`

In the moved file:
- Class `StartGenerationTest` → `CreateApplicationTest`
- `@tool = CreateApplication.new(project: @project)`
- All `StartGeneration.new(...)` → `CreateApplication.new(...)`
- Stub helper `stub_create_plan` is unchanged (already uses `PlanApplicationCreation` after Phase 1)

#### 5. Update integration test stubs
**File**: `test/integration/generate_todo_list_test.rb`
- Any `Chat#complete` stub that simulates a `start_generation` tool call must use `create_application` as the tool name. Locate the LLM-stub code and update tool-name strings.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` — same 9 pre-existing preview_manager failures only; all rename-affected tests (31) pass
- [x] `grep -r "StartGeneration" app/ test/ config/` returns no matches
- [x] `grep -r "start_generation" app/ test/ config/` returns no matches (also clean in `bin/`)
- [x] `bin/rails runner 'puts CreateApplication.new(project: Project.first).name'` prints `create_application`

#### Manual Verification:
- [x] CreateApplication tool smoke via `bin/rails runner`: with stubbed PlanApplicationCreation, `CreateApplication#execute` persists Instruction (phase=implementing, 3 revisions) and returns the expected hash
- [x] Existing `bin/generate full` smoke path — exercised via runner equivalent (same code path)

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 3 — Add `PlanApplicationModification` planner

### Commit
`chat-agent: add PlanApplicationModification planner`

### Overview
Net-new planner module mirroring `PlanApplicationCreation`'s shape. No caller yet — Phase 4 introduces the tool that uses it.

### Changes Required

#### 1. Create the façade
**File**: `app/services/plan_application_modification.rb`
```ruby
module PlanApplicationModification
  Result = Struct.new(:instruction_description, :revisions, keyword_init: true)

  class << self
    def call(intent:, clarifications: {}, context: {}, openrouter_api_key:)
      implementation.call(
        intent: intent,
        clarifications: clarifications,
        context: context,
        openrouter_api_key: openrouter_api_key
      )
    end

    def implementation
      @implementation ||= AdHocLLM
    end

    attr_writer :implementation
  end
end
```

#### 2. Create the AdHocLLM adapter
**File**: `app/services/plan_application_modification/ad_hoc_llm.rb`
```ruby
module PlanApplicationModification
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/plan_application_modification_system.md").read.freeze
    MODEL = "anthropic/claude-haiku-4.5"

    class InvalidResponse < StandardError; end

    def self.call(intent:, clarifications:, context:, openrouter_api_key:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      content = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt, openrouter_api_key: openrouter_api_key)
      build_result(content)
    end

    def self.invoke_llm(system:, user:, openrouter_api_key:)
      ctx = RubyLLM.context { |c| c.openrouter_api_key = openrouter_api_key }
      chat = ctx.chat(model: MODEL)
      chat.with_instructions(system)
      chat.with_schema(PlanSchema).ask(user).content
    end

    def self.build_user_prompt(intent, clarifications, _context)
      lines = ["Intent: #{intent}"]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      lines.join("\n")
    end

    def self.build_result(content)
      raise InvalidResponse, "LLM returned no content" if content.nil?

      revisions = Array(content["revisions"]).map do |r|
        { summary: r.fetch("summary"), prompt: r.fetch("prompt") }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?

      PlanApplicationModification::Result.new(
        instruction_description: content.fetch("instruction_description"),
        revisions: revisions
      )
    rescue KeyError => e
      raise InvalidResponse, "plan missing field: #{e.message}"
    end
  end
end
```

This is a near-copy of `PlanApplicationCreation::AdHocLLM` with two changes: the `SYSTEM_PROMPT` path and the result class. `PlanSchema` is shared.

#### 3. Create the modification system prompt
**File**: `app/prompts/plan_application_modification_system.md`
```markdown
You are a Rails application planner. The application already exists in the workspace — Rails 8 is installed, gems are bundled, and previous revisions have shaped the schema, routes, views, and Tailwind theme.

Your job: given a user's plain-language change request, emit a short plan of one or more atomic revisions matching the required JSON schema.

Rules for the plan:
- 1 to 6 revisions. PREFER A SINGLE REVISION whenever the change is small and self-contained (a styling tweak, a copy change, one new field). Use multiple revisions only when the user is asking for a substantive refactor that genuinely needs sequencing (e.g. "replace the storybook with a kanban board").
- Each revision is one atomic, testable change.
- DO NOT change the root route unless the user explicitly asks for it.
- DO NOT re-introduce models, controllers, or views that already exist. Reference existing files by path; describe modifications rather than scaffolds.
- DO NOT add a navigation menu unless the user explicitly asks for one. Modify the existing navigation only when relevant.
- Assume Tailwind, Hotwire, Devise, and the previously picked template's design tokens are already wired. Reference existing CSS variables (e.g. `--accent`, `--paper-100`) when applicable rather than introducing new ones.
- Never reference "Claude", "Anthropic", or any LLM provider unless the user explicitly asks for that integration.
- Each revision's `prompt` is the full instruction passed to the implementer agent — concrete, file-level, verifiable. Mention specific files (e.g. "in `app/views/layouts/application.html.erb`, change …").
- Each revision's `summary` is a git-commit-style one-liner.

Emit the complete plan in the required JSON shape. Do not respond with prose.
```

#### 4. Tests for the façade
**File**: `test/services/plan_application_modification_test.rb`
Mirror `test/services/plan_application_creation_test.rb`:
- "default implementation is AdHocLLM"
- "delegates call to the configured implementation with same args"
- "implementation= swaps the active implementation"

#### 5. Tests for the AdHocLLM adapter
**File**: `test/services/plan_application_modification/ad_hoc_llm_test.rb`
Mirror `test/services/plan_application_creation/ad_hoc_llm_test.rb`:
- happy path: returns Result built from schema response
- passes system prompt and user prompt with intent to the LLM
- includes clarifications in the user prompt when present
- raises InvalidResponse when LLM returns no content
- raises InvalidResponse when revisions array is empty (single-revision plans are valid; **empty** is not)
- raises InvalidResponse when instruction_description key missing
- raises InvalidResponse when revision is missing summary
- raises InvalidResponse when revision is missing prompt
- propagates errors from the LLM

#### 6. Test fixtures
**Create**: `test/fixtures/files/plan_application_modification/valid_plan.json`
```json
{
  "instruction_description": "Set primary color to teal across the storybook UI.",
  "revisions": [
    {
      "summary": "Update primary color CSS variable to teal",
      "prompt": "In app/assets/tailwind/application.css, change the value of --accent to a teal hex (e.g. #0D9488). Also update any inline yellow color classes in app/views/stories/index.html.erb to teal equivalents."
    }
  ]
}
```

**Create**: `test/fixtures/files/plan_application_modification/empty_revisions.json` — same shape, `"revisions": []`.
**Create**: `test/fixtures/files/plan_application_modification/missing_description.json` — drop `instruction_description`.
**Create**: `test/fixtures/files/plan_application_modification/missing_summary.json` — drop `summary` from a revision.
**Create**: `test/fixtures/files/plan_application_modification/missing_prompt.json` — drop `prompt` from a revision.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test test/services/plan_application_modification_test.rb` — all green
- [x] `bin/rails test test/services/plan_application_modification/ad_hoc_llm_test.rb` — all green
- [x] `bin/rails test` — 272 runs (12 new), only the 9 pre-existing preview_manager failures
- [x] `bin/rails runner 'puts PlanApplicationModification::AdHocLLM::SYSTEM_PROMPT.length'` prints `1754`

#### Manual Verification:
- [x] None at this phase — service is not yet wired into any user-facing path. Phase 5 is where this becomes user-visible.

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 4 — Add `ModifyApplication` tool (not yet bound)

### Commit
`chat-agent: add ModifyApplication tool`

### Overview
New `RubyLLM::Tool` that mirrors `CreateApplication` but calls `PlanApplicationModification`. Not yet bound to `GeneratorAgent` — Phase 5 wires it.

### Changes Required

#### 1. Create the tool
**File**: `app/tools/modify_application.rb`
```ruby
class ModifyApplication < RubyLLM::Tool
  def name = "modify_application"
  description "Modifies the existing application based on the user's change request. " \
              "Call this when the project already has a generated application and the user wants a change. " \
              "The user must have explicitly confirmed they're ready to apply the change before you call this."

  params do
    string :intent,
           description: "Plain-language description of the change the user wants, e.g. 'make the primary color teal'."
    object :clarifications,
           description: "Answers to clarifying questions, as key-value pairs. Empty object if none." do
      additional_properties true
    end
  end

  def initialize(project:)
    super()
    @project = project
  end

  def execute(intent:, clarifications: {})
    if @project.instructions.where.not(phase: %w[completed failed cancelled]).exists?
      return {
        error: "A generation is already in progress. Tell the user you'll start their next change once the current build finishes."
      }
    end

    result = PlanApplicationModification.call(
      intent: intent,
      clarifications: clarifications,
      context: { project_id: @project.id },
      openrouter_api_key: @project.user.profile.openrouter_api_key
    )

    instruction = nil
    ActiveRecord::Base.transaction do
      instruction = @project.instructions.create!(
        user_intent: intent,
        description: result.instruction_description,
        phase: :implementing,
        anchor_message: anchor_message
      )

      previous = nil
      result.revisions.each_with_index do |r, i|
        previous = instruction.revisions.create!(
          project: @project,
          summary: r[:summary],
          prompt: r[:prompt],
          position: i,
          status: :pending,
          parent: previous
        )
      end
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
  rescue PlanApplicationModification::AdHocLLM::InvalidResponse => e
    { error: "Could not generate a modification plan: #{e.message}. Ask the user to rephrase." }
  end

  private

  def anchor_message
    @project.chat.messages.where(role: :user).order(:id).last
  end
end
```

The body is structurally identical to `CreateApplication#execute`. The differences:
- `description` text (creation vs modification context).
- `intent` param description (build a thing vs change a thing).
- Calls `PlanApplicationModification.call` instead of `PlanApplicationCreation.call`.
- Rescues `PlanApplicationModification::AdHocLLM::InvalidResponse` and returns a slightly differently-worded error.

The in-progress guard, transactional persistence, and `instruction.requested` notification are unchanged.

#### 2. Create the test
**File**: `test/tools/modify_application_test.rb`
Mirror `test/tools/create_application_test.rb` with these adaptations:
- Setup: pre-initialize the workspace with a fake `Gemfile` so the project looks already-built. (See snippet below.)
- Stub `PlanApplicationModification` instead of `PlanApplicationCreation`.
- Plan fixture has a single-revision shape (closer to typical modification output).

```ruby
require "test_helper"

class ModifyApplicationTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Storybook", user: users(:owner))
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "make the primary color teal")
    @tool = ModifyApplication.new(project: @project)

    @plan = PlanApplicationModification::Result.new(
      instruction_description: "Set primary color to teal.",
      revisions: [
        {
          summary: "Update primary color to teal",
          prompt: "In app/assets/tailwind/application.css, change --accent to a teal hex."
        }
      ]
    )
  end

  def stub_planner(result_or_proc)
    original = PlanApplicationModification.method(:call)
    PlanApplicationModification.define_singleton_method(:call) do |**kwargs|
      result_or_proc.respond_to?(:call) ? result_or_proc.call(**kwargs) : result_or_proc
    end
    yield
  ensure
    PlanApplicationModification.define_singleton_method(:call, original) if original
  end

  test "persists an Instruction with user_intent, description, implementing phase, and user anchor_message" do
    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal "make the primary color teal", instruction.user_intent
    assert_equal "Set primary color to teal.", instruction.description
    assert_equal "implementing", instruction.phase
    assert_equal @user_message, instruction.anchor_message
  end

  test "persists a single Revision with position 0 and status pending" do
    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    revisions = @project.instructions.order(:id).last.revisions.order(:position)
    assert_equal 1, revisions.size
    assert_equal 0, revisions.first.position
    assert_equal "pending", revisions.first.status
    assert_equal @plan.revisions.first[:summary], revisions.first.summary
    assert_equal @plan.revisions.first[:prompt], revisions.first.prompt
    assert_nil revisions.first.parent
  end

  test "persists multiple Revisions chained via parent for a multi-revision modification plan" do
    multi = PlanApplicationModification::Result.new(
      instruction_description: "Replace storybook with kanban board.",
      revisions: [
        { summary: "Add Board model", prompt: "..." },
        { summary: "Add BoardsController + routes", prompt: "..." },
        { summary: "Add Tailwind kanban views", prompt: "..." }
      ]
    )

    stub_planner(multi) do
      @tool.execute(intent: "replace storybook with a kanban board", clarifications: {})
    end

    revisions = @project.instructions.order(:id).last.revisions.order(:position)
    assert_equal 3, revisions.size
    assert_nil revisions[0].parent
    assert_equal revisions[0], revisions[1].parent
    assert_equal revisions[1], revisions[2].parent
  end

  test "emits instruction.requested notification with instruction_id" do
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
      payloads << payload
    end

    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal 1, payloads.size
    assert_equal instruction.id, payloads.first[:instruction_id]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "returns a Hash with instruction_id, revision_count, instruction_description" do
    result = nil
    stub_planner(@plan) do
      result = @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal(
      { instruction_id: instruction.id, revision_count: 1, instruction_description: "Set primary color to teal." },
      result
    )
  end

  test "on PlanApplicationModification InvalidResponse: returns error hash, persists nothing, no notification" do
    raising = ->(**) { raise PlanApplicationModification::AdHocLLM::InvalidResponse, "empty revisions" }
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| payloads << p }

    result = nil
    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_planner(raising) do
          result = @tool.execute(intent: "x", clarifications: {})
        end
      end
    end

    assert_match(/Could not generate a modification plan/, result[:error])
    assert_empty payloads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "on unexpected error from PlanApplicationModification: propagates and persists nothing" do
    raising = ->(**) { raise RuntimeError, "upstream boom" }

    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_planner(raising) do
          assert_raises(RuntimeError) { @tool.execute(intent: "x", clarifications: {}) }
        end
      end
    end
  end

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
        stub_planner(@plan) do
          result = @tool.execute(intent: "second change", clarifications: {})
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

    stub_planner(@plan) do
      result = @tool.execute(intent: "second change", clarifications: {})
      assert result[:instruction_id].present?
      refute result.key?(:error)
    end
  end
end
```

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test test/tools/modify_application_test.rb` — 9/9 tests pass
- [x] `bin/rails test` — 281 runs, only 9 pre-existing preview_manager failures
- [x] `bin/rails runner 'puts ModifyApplication.new(project: Project.first).name'` prints `modify_application`

#### Manual Verification:
- [x] None at this phase — tool is not yet bound to the agent. Phase 5 wires it.

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 5 — `GeneratorAgent` gates tool surface on `workspace_initialized?` (Bug A fix)

### Commit
`chat-agent: bind one mutation tool per workspace state`

### Overview
This is where Bug A goes away. `GeneratorAgent#tools` becomes conditional on `Project#workspace_initialized?`. After this phase, a tweak sent to a project with an existing app routes through `modify_application` and produces a single-revision modification instead of a 6-revision rebuild.

### Changes Required

#### 1. Update GeneratorAgent
**File**: `app/agents/generator_agent.rb`
```ruby
class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  instructions { prompt("instructions", current_state: chat.project.current_state_prompt) }

  tools do
    project = chat.project
    mutation_tool = if project.workspace_initialized?
      ModifyApplication.new(project: project)
    else
      CreateApplication.new(project: project)
    end
    [mutation_tool, SuggestPrompts.new(project: project)]
  end
end
```

#### 2. Update agent prompt to mention both tools by name
**File**: `app/prompts/generator_agent/instructions.txt.erb`

Replace "Call `create_application`…" wording with branching language. Phase 6 will rewrite the prompt for confirmation-first; in this phase, a minimal edit:

```erb
You are an assistant helping the user describe a Rails web application they want to build.

Guidelines:
- Ask at most 2 clarifying questions. Prefer building with reasonable defaults over interrogating.
- When the user's intent is clear and the user has confirmed, call the `create_application` tool (for a brand-new project, no app yet) OR the `modify_application` tool (for changes to an existing app). Only ONE of these is bound at any time — use whichever is offered.
- Pass `intent:` as a plain-language description of what they want. Pass `clarifications:` as a hash of the specific answers you gathered; pass `{}` if there were none.
- Do NOT generate an implementation plan yourself. Do NOT list models, controllers, or files. That's not your job — the backend handles it.
- After `create_application`/`modify_application` returns, summarise what you started in 1-2 sentences, and then call the `suggest_prompts` tool with 3-5 natural next steps.
- Do NOT call `create_application`/`modify_application` again while a previous generation is still running. If the user asks for more changes during a build, acknowledge their request and tell them you'll handle it as soon as the current build finishes. Keep the conversation moving — don't go silent.
- You may also call `suggest_prompts` at other moments when offering the user a direction to take the conversation.
- Call each tool AT MOST ONCE per user turn. After a tool returns, write your final reply as plain text and stop — do not call the same tool again until the user replies. Calling the same tool twice in one turn corrupts the conversation history and prevents any further messages.

Current project state:
<%= current_state %>
```

(Phases 6-7 will further rewrite this.)

#### 3. New agent test
**File**: `test/agents/generator_agent_test.rb` (NEW)
```ruby
require "test_helper"

class GeneratorAgentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Test", user: users(:owner))
    @chat = @project.create_chat!
  end

  test "binds CreateApplication when workspace is not initialized" do
    refute @project.workspace_initialized?, "test setup expected uninitialized workspace"

    agent = GeneratorAgent.find(@chat.id)
    tool_classes = agent.send(:tools).map(&:class)
    assert_includes tool_classes, CreateApplication
    refute_includes tool_classes, ModifyApplication
    assert_includes tool_classes, SuggestPrompts
  end

  test "binds ModifyApplication when workspace is initialized" do
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), "# fake")
    assert @project.workspace_initialized?

    agent = GeneratorAgent.find(@chat.id)
    tool_classes = agent.send(:tools).map(&:class)
    assert_includes tool_classes, ModifyApplication
    refute_includes tool_classes, CreateApplication
    assert_includes tool_classes, SuggestPrompts
  ensure
    FileUtils.rm_rf(@project.workspace_path) if @project.workspace_path
  end
end
```

Note: `agent.send(:tools)` accesses the private tools list; if `RubyLLM::Agent` exposes a public reader, prefer that. If not, the `send` is the test-time accessor (the tool list is what RubyLLM uses internally to register).

If `GeneratorAgent.find(chat_id)` doesn't expose the tool list directly, an alternative test approach: instantiate `GeneratorAgent.new(chat: @chat)` (or whatever the construction surface is) and call the `tools do ... end` block evaluator. The test should be adapted to the actual agent API; the contract being tested is "exactly one mutation tool is bound per workspace state."

#### 4. Adapt existing integration test
**File**: `test/integration/generate_todo_list_test.rb`

The test starts with an uninitialized workspace (fresh project) and expects `create_application` to be called. After Phase 5 this still works because `workspace_initialized?` returns false until Roast lays down the Gemfile. No code changes needed if the test already uses the renamed tool name (Phase 2). Verify by running.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test test/agents/generator_agent_test.rb` — 3/3 tests pass; verifies CreateApplication for empty workspace and ModifyApplication for initialized workspace, with mutual exclusion
- [x] `bin/rails test` — 284 runs, only 9 pre-existing preview_manager failures
- [ ] `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` — gated E2E (real Roast subprocess, ~8 min, burns Claude tokens) — not run by default

#### Manual Verification:
- [x] **Bug A reproduction smoke (logic level)**: verified via `bin/rails runner` — `Project#workspace_initialized?` returns false for a fresh project, true after a Gemfile is laid down. Combined with the agent test (Phase 5 binds CreateApplication when false, ModifyApplication when true), this proves that a tweak after a completed build cannot route through CreateApplication.
- [x] On a brand-new project (empty workspace), `create_application` is bound (verified by `binds CreateApplication when workspace is not initialized` agent test).

**Implementation Note**: pause here for manual confirmation before proceeding. Bug A is the highest-impact fix — verify it from the user's seat before moving on.

---

## Phase 6 — Confirmation-first prompt update

### Commit
`chat-agent: require user confirmation before mutation tools`

### Overview
Behavioral change. The chat agent must summarise the user's intent and explicitly ask for confirmation BEFORE calling `create_application`/`modify_application`. The mutation tool only fires after the user's affirmative reply.

This phase changes only the system prompt + adds a small comment in `GeneratorAgent`. No code-level changes to tools or services. Verification is largely manual since prompt behavior depends on Haiku.

### Changes Required

#### 1. Update agent system prompt
**File**: `app/prompts/generator_agent/instructions.txt.erb`
```erb
You are an assistant helping the user describe a Rails web application they want to build, and helping them iterate on it once it exists.

Two states matter for your behavior:

A) THE USER IS DESCRIBING WORK YOU HAVEN'T STARTED YET.
   - Ask at most 2 clarifying questions. Prefer reasonable defaults over interrogating.
   - When you understand the user's intent, **summarise it back in 1-2 sentences and ASK** ("Ready to start?" / "Should I apply this?"). Do NOT call `create_application` or `modify_application` yet.
   - Only AFTER the user's NEXT message confirms ("yes", "go ahead", "do it", "proceed", or any clear affirmation), call `create_application` (for a brand-new project) OR `modify_application` (for a change to an existing app). Only ONE of these tools is bound at any time — use whichever is offered.
   - Pass `intent:` as a plain-language description. Pass `clarifications:` as a hash of the specific answers you gathered; pass `{}` if there were none.

B) A GENERATION IS CURRENTLY RUNNING.
   - Do NOT call `create_application` or `modify_application`.
   - Do NOT claim any new work has been done — it hasn't.
   - Chat normally with the user. If they describe a change, acknowledge it ("I'll bring that up once the current build finishes") and keep the conversation moving. Don't go silent.

GENERAL RULES:
- Do NOT generate an implementation plan yourself. Do NOT list models, controllers, or files. That's the backend's job.
- After `create_application`/`modify_application` returns, do NOT write any text. The system itself will display a "🌀 Building…" status. Call `suggest_prompts` with 3-5 natural next steps and STOP — no narration, no completion language. The build is just starting; nothing has been done yet.
- You may also call `suggest_prompts` at other moments when offering the user a direction to take the conversation.
- Call each tool AT MOST ONCE per user turn. After a tool returns, write your final reply (or no reply at all, per the rule above) and stop — do not call the same tool again until the user replies. Calling the same tool twice in one turn corrupts the conversation history.

Current project state:
<%= current_state %>
```

The "no text after the mutation tool" rule is included here because Phase 7 introduces the system-emitted "🌀 Building…" message that replaces the LLM's narration; including it now in the prompt ensures Phase 6 doesn't ship a confirmation-flow + still-narrating LLM combo (which would confuse the UX).

#### 2. Update `Project#current_state_prompt` to align with the new prompt
**File**: `app/models/project.rb` (lines 45-54)

The two strings should match the prompt's two states:
```ruby
def current_state_prompt
  active = instructions
    .where.not(phase: %w[completed failed cancelled])
    .order(:created_at).last
  return "STATE A — No generation is currently running. You may guide the user toward a build/change, but only call `create_application`/`modify_application` AFTER the user explicitly confirms in their next message." unless active

  total = active.revisions.count
  done = active.revisions.where(status: :completed).count
  "STATE B — A generation is CURRENTLY RUNNING (instruction ##{active.id}, #{done}/#{total} revisions complete). Do NOT call `create_application` or `modify_application`. Do NOT claim any new work has been done — it hasn't. Tell the user you'll start their next change once the current build finishes."
end
```

The "STATE A / STATE B" markers explicitly key into the prompt's lettered sections.

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` — 284 runs, only the 9 pre-existing preview_manager failures; chat_respond_job_test's string-match assertion was updated to match the new "or `modify_application`" wording

#### Manual Verification:
- [ ] **Confirmation flow smoke**: on a fresh project, type "build a todo list." Verify the LLM responds with a summary + question (e.g. "Got it — a todo list with…. Ready to start?") and does NOT call `create_application` in this turn (no Instruction created, no Roast subprocess kicked off). — depends on Haiku obeying the new prompt; left for live verification
- [ ] Reply "yes" — verify the LLM now calls `create_application` and an Instruction is created.
- [ ] On an existing project (workspace initialized), type "make banner green." Verify the LLM responds with summary + ask, no tool call.
- [ ] Reply "do it" — verify `modify_application` fires.
- [ ] Type "build a todo list, just go" on a fresh project. Acceptable: LLM may interpret "just go" as in-message confirmation and call the tool in the same turn. Either behavior is fine; this is the eager-confirmation edge case.
- [x] STATE A / STATE B prompt text verified via `bin/rails runner` — both branches of `Project#current_state_prompt` produce the expected new wording aligned with the prompt's lettered sections.

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 7 — System-emitted starting message; LLM stops post-tool narration (Bug B fix)

### Commit
`chat-agent: emit '🌀 Building…' as system message after generation starts`

### Overview
A new `instruction.requested` subscriber posts an assistant message `"🌀 Building: <description>"` as soon as the build is queued. Symmetric to the existing `instruction.completed` subscriber that posts `"✅ Generation finished."`.

The agent prompt's "do NOT write text after the mutation tool" rule (added in Phase 6) is now backed by a system-emitted indicator, so the user sees a clean start-of-build status.

After this phase: the string `"Done!"` (or any past-tense completion language) cannot appear in an assistant message body within seconds of a `create_application`/`modify_application` call, because the LLM is forbidden from writing text and the only system-posted message is the future-tense `"🌀 Building: …"`.

### Changes Required

#### 1. Add the new subscriber
**File**: `config/initializers/event_subscribers.rb`

Add at the bottom of the existing `instruction.requested` subscribers block:
```ruby
# After the LLM has just called create_application/modify_application, the
# user needs an immediate "build started" indicator. The LLM itself is forbidden
# (per the agent prompt) from narrating around the tool call — so we post the
# starting message here, symmetric to "✅ Generation finished." on completion.
ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  instruction.project.chat.messages.create!(
    role: :assistant,
    content: "🌀 Building: #{instruction.description}"
  )
end
```

#### 2. Extend the event-bus test
**File**: `test/integration/event_subscribers_test.rb`

Add at the bottom of the existing tests:
```ruby
test "instruction.requested persists a 🌀 Building assistant message" do
  assert_difference -> { @chat.messages.where(role: :assistant).count }, 1 do
    ActiveSupport::Notifications.instrument(
      "instruction.requested",
      instruction_id: @instruction.id
    )
  end

  msg = @chat.messages.where(role: :assistant).order(:id).last
  assert_match(/^🌀 Building: /, msg.content)
  assert_includes msg.content, @instruction.description
end
```

Also update the existing test "instruction.requested broadcasts the revisions list partial to active_revisions" to expect 2 broadcasts (the existing list partial + the new assistant message broadcast that fires via `Message#broadcast_append_message`):
```ruby
test "instruction.requested broadcasts the revisions list partial AND the building-status message" do
  assert_broadcasts(@stream_name, 2) do
    ActiveSupport::Notifications.instrument(
      "instruction.requested",
      instruction_id: @instruction.id
    )
  end
end
```

(The exact broadcast count depends on whether `Message#broadcast_append_message` and the explicit subscriber broadcast both fire to the same stream. Run the test and adjust the count to match observed behavior.)

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test test/integration/event_subscribers_test.rb` — all green
- [ ] `bin/rails test` — full suite green

#### Manual Verification:
- [ ] **Bug B reproduction smoke**: send "build a todo list" → confirm at the prompt → wait for the `create_application` tool call. Within 1-2 seconds, the chat should show:
  1. The user message
  2. The assistant turn (likely with no body content, only `tool_calls`) — Message#visible_in_chat? hides empty assistant messages
  3. **`🌀 Building: <description>`** — the new system-emitted message
  4. The `suggest_prompts` partial (next-step pills)
- [ ] Verify that NO assistant message contains "Done!" or "Updated" or "Finished" or any past-tense completion language during this window.
- [ ] Wait for the build to complete (5-10 min) → confirm `✅ Generation finished.` appears (existing behavior).

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 8 — Auto-recap on `instruction.completed` (Bug C fix)

### Commit
`chat-agent: auto-recap and prompt user after generation finishes`

### Overview
The `instruction.completed` subscriber gains a follow-up: it persists a hidden synthetic user message instructing the LLM to recap any pending mid-build user messages and ask the user what to do next. The LLM produces text only; no tool call. The user reads the recap and replies in their own words; the regular `ChatRespondJob` then runs the confirmation flow.

This phase introduces the only schema change in the plan: a `system_injected:boolean` column on `messages` so the synthetic nudge is hidden in the UI.

### Changes Required

#### 1. Add migration
**File**: `db/migrate/<timestamp>_add_system_injected_to_messages.rb`
```ruby
class AddSystemInjectedToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :system_injected, :boolean, default: false, null: false
  end
end
```

Run `bin/rails db:migrate`.

#### 2. Update Message visibility
**File**: `app/models/message.rb`
```ruby
class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments

  after_create_commit :broadcast_append_message
  after_update_commit :broadcast_replace_message

  def visible_in_chat?
    return false if system_injected?
    return true if role == "user"
    role == "assistant" && (content.to_s.strip.present? || tool_calls.any?)
  end

  private

  def broadcast_append_message
    return unless %w[user assistant].include?(role)
    return if system_injected?  # hidden messages do not broadcast their own append

    broadcast_append_later_to chat.project,
      target: "messages",
      partial: "messages/message",
      locals: { message: self }
  end

  def broadcast_replace_message
    return if system_injected?

    broadcast_replace_later_to chat.project,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "messages/message",
      locals: { message: self }
  end
end
```

The `system_injected?` predicate comes from the boolean column automatically. Hidden messages neither render in the chat list nor broadcast their own create/replace events.

Verify the chat-rendering view/partial uses `chat.messages.where(...)` or iterates `chat.messages` — if it does, ensure rendering filters by `visible_in_chat?` already (it should, since `visible_in_chat?` was already used). If the rendering path bypasses `visible_in_chat?` (e.g. iterates raw messages), update the view to filter.

#### 3. Add auto-recap subscriber
**File**: `config/initializers/event_subscribers.rb`

Add after the existing `instruction.completed` subscriber (the one that posts `"✅ Generation finished."`):
```ruby
# After every completed instruction, fire one LLM turn to recap and ask the
# user what's next. The LLM is forbidden (via the synthetic nudge body) from
# calling any tool — its job is text-only summary + question. The user's
# next reply re-enters the normal confirmation flow.
#
# This is how mid-build user messages get surfaced for explicit confirmation
# rather than being silently dropped.
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  chat = instruction.project.chat

  pending = chat.messages
    .where(role: :user, system_injected: false)
    .where("id > ?", instruction.anchor_message_id)
    .order(:id)

  pending_section = if pending.empty?
    "(no messages were sent during the build.)"
  else
    pending.map { |m| "- #{m.content}" }.join("\n")
  end

  nudge_body = <<~NUDGE
    [Auto-resume after instruction ##{instruction.id} completed.]

    Messages the user sent while the build was running:
    #{pending_section}

    Your job in this turn:
    1. If the user sent change requests during the build, recap them in 1-2 sentences and ask whether to proceed (without applying anything yet).
    2. If they sent no change requests (or only questions), acknowledge that the build finished and ask what they want next.
    3. DO NOT call create_application or modify_application. DO NOT call any other tool. Reply with text only.
  NUDGE

  nudge_msg = chat.messages.create!(
    role: :user,
    content: nudge_body,
    system_injected: true
  )

  ChatRespondJob.perform_later(nudge_msg.id)
end
```

#### 4. Verify ChatRespondJob handles the synthetic nudge
**File**: `app/jobs/chat_respond_job.rb` — should require no changes. The job's perform path:
```ruby
def perform(message_id)
  user_message = Message.find(message_id)
  chat = user_message.chat
  ...
  agent = GeneratorAgent.find(user_message.chat_id)
  agent.with_context(ctx).complete do |chunk|
    ...
  end
end
```

This works for the synthetic nudge as-is: it's a `Message` with role `:user`, the chat hydrates normally, the agent's `complete` runs against the full message history (including the hidden nudge as the latest user message). RubyLLM sends the full history to the LLM API; the LLM responds; the assistant message is created and streamed.

The only consideration: the `system_injected` flag affects UI rendering, NOT the LLM's view. The LLM sees the nudge as a user message in its context. That is the desired behavior — the nudge is the LLM's "instruction" for that turn.

#### 5. Tests
**File**: `test/integration/event_subscribers_test.rb`

Add:
```ruby
test "instruction.completed persists a hidden synthetic nudge user message" do
  assert_difference -> { @chat.messages.where(system_injected: true).count }, 1 do
    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: @instruction.id
    )
  end

  nudge = @chat.messages.where(system_injected: true).order(:id).last
  assert_equal "user", nudge.role
  assert_includes nudge.content, "Auto-resume"
  refute nudge.visible_in_chat?
end

test "instruction.completed enqueues a ChatRespondJob for the synthetic nudge" do
  assert_enqueued_jobs 1, only: ChatRespondJob do
    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: @instruction.id
    )
  end

  nudge = @chat.messages.where(system_injected: true).order(:id).last
  job = enqueued_jobs.find { |j| j["job_class"] == "ChatRespondJob" }
  assert_equal nudge.id, job["arguments"].first
end

test "instruction.completed lists pending mid-build user messages in the nudge body" do
  pending = @chat.messages.create!(role: :user, content: "make the banner green")
  pending2 = @chat.messages.create!(role: :user, content: "and add a logo")

  ActiveSupport::Notifications.instrument(
    "instruction.completed",
    instruction_id: @instruction.id
  )

  nudge = @chat.messages.where(system_injected: true).order(:id).last
  assert_includes nudge.content, "make the banner green"
  assert_includes nudge.content, "and add a logo"
end

test "instruction.completed includes a 'no messages' marker when none were sent during the build" do
  ActiveSupport::Notifications.instrument(
    "instruction.completed",
    instruction_id: @instruction.id
  )

  nudge = @chat.messages.where(system_injected: true).order(:id).last
  assert_match(/no messages were sent/, nudge.content)
end
```

**File**: `test/models/message_test.rb` — add (create file if it doesn't exist):
```ruby
require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Test", user: users(:owner))
    @chat = @project.create_chat!
  end

  test "system_injected user messages are not visible_in_chat" do
    msg = @chat.messages.create!(role: :user, content: "hi", system_injected: true)
    refute msg.visible_in_chat?
  end

  test "regular user messages are visible_in_chat" do
    msg = @chat.messages.create!(role: :user, content: "hi", system_injected: false)
    assert msg.visible_in_chat?
  end

  test "system_injected does not broadcast append" do
    # Inferred from absence of broadcast — concrete assertion depends on
    # ActionCable test helpers' shape.
    assert_no_broadcasts(@project.to_gid_param) do
      @chat.messages.create!(role: :user, content: "hi", system_injected: true)
    end
  end
end
```

Test #3 may need adaptation depending on the project's ActionCable test conventions; the contract is "system_injected messages do not broadcast."

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails db:migrate` — migration applies cleanly
- [ ] `bin/rails test test/integration/event_subscribers_test.rb` — green
- [ ] `bin/rails test test/models/message_test.rb` — green
- [ ] `bin/rails test` — full suite green
- [ ] `bin/rails runner 'puts Message.column_names.include?("system_injected")'` prints `true`

#### Manual Verification:
- [ ] **Bug C reproduction smoke**: on an existing project (workspace initialized), start a `modify_application` build that takes a few minutes (e.g. "replace the storybook with a kanban board"). While it's running, send "make the banner green." The LLM should reply (chat-only) acknowledging the deferral; no tool fires.
- [ ] Wait for the build to complete (`✅ Generation finished.` appears).
- [ ] Within ~30 seconds, an additional assistant message appears: a recap referencing "make the banner green" and asking whether to apply it.
- [ ] Reply "yes, apply it" → verify `modify_application` fires for the deferred request.
- [ ] **No-deferred case**: complete a generation without sending mid-build messages. Verify the recap message appears with text along the lines of "Build finished. Let me know what to change next" — no spurious "you asked for X" content.
- [ ] **UI hidden-message check**: in the rails console, `Project.last.chat.messages.where(system_injected: true)` should show the synthetic nudges. Open the chat in the browser and confirm those nudges do NOT render visually.

**Implementation Note**: pause here for manual confirmation before proceeding.

---

## Phase 9 — End-to-end integration test for design-tweak flow

### Commit
`chat-agent: integration test for modify_application happy path`

### Overview
A gated integration test (similar to `test/integration/generate_todo_list_test.rb`) drives the full design-tweak flow with stubbed planners and a stubbed `Chat#complete`. Asserts:
- Pre-initialized workspace + completed instruction → next message routes through `modify_application`, not `create_application`.
- The confirmation flow is enforced (the LLM-stub's first turn produces text + question, no tool call; the second turn after the user "confirms" produces the tool call).
- Only ONE new Instruction is created with the right Revision count from the modification fixture.
- The auto-recap subscriber fires after `instruction.completed`.

This test runs without `E2E_GENERATE` because it stubs the LLM and the planner; no Roast subprocess is invoked.

### Changes Required

#### 1. Create the modification fixture
**File**: `test/fixtures/plans/banner_green.rb`
```ruby
module PlanFixtures
  def self.banner_green
    PlanApplicationModification::Result.new(
      instruction_description: "Change the top banner to green.",
      revisions: [
        {
          summary: "Update banner color in application layout",
          prompt: "In app/views/layouts/application.html.erb, change the banner background color from yellow to green. Verify by inspecting the rendered class on the banner element."
        }
      ]
    )
  end
end
```

#### 2. Create the integration test
**File**: `test/integration/modify_application_after_completion_test.rb`
```ruby
require "test_helper"

# Drives the design-tweak flow end-to-end with stubbed planners and stubbed
# Chat#complete. Verifies that a tweak after a completed build:
# - routes through modify_application (not create_application — Bug A)
# - requires user confirmation before firing the tool
# - produces a single-revision modification (no rebuild)
# - triggers the auto-recap on instruction.completed (Bug C path)
class ModifyApplicationAfterCompletionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:owner)
    @project = Project.create!(name: "Storybook", user: @user)
    @chat = @project.create_chat!

    # Pre-initialize the workspace so workspace_initialized? returns true.
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), "# fake")

    # Pre-create a completed instruction so this is unambiguously a tweak path.
    seed_user_msg = @chat.messages.create!(role: :user, content: "build a storybook")
    @prior_instruction = @project.instructions.create!(
      user_intent: "build a storybook",
      description: "Build a children's storybook app.",
      phase: :completed,
      anchor_message: seed_user_msg
    )

    # Swap planner implementation to fixture
    @original_planner = PlanApplicationModification.implementation
    PlanApplicationModification.implementation = fake_planner_returning(PlanFixtures.banner_green)
  end

  teardown do
    PlanApplicationModification.implementation = @original_planner if @original_planner
    FileUtils.rm_rf(@project.workspace_path) if @project.workspace_path
  end

  test "tweak after completed build routes through modify_application with one revision" do
    # Step 1: user describes the change
    user_msg = @chat.messages.create!(role: :user, content: "make the banner green")

    # Step 2: stub the LLM to drive the confirmation flow.
    # First turn: text-only summary + question (no tool call).
    # Second turn: user confirms → modify_application tool call.
    with_chat_complete_stub(scripted_turns: [
      { text: "Got it — I'll change the banner color from yellow to green. Should I apply this?" },
      { tool_call: { name: "modify_application", arguments: { intent: "change banner to green", clarifications: {} } } }
    ]) do
      # User's first message → confirmation question, no Instruction yet.
      assert_no_difference -> { Instruction.count } do
        ChatRespondJob.perform_now(user_msg.id)
      end

      # User confirms.
      confirm_msg = @chat.messages.create!(role: :user, content: "yes, apply it")
      assert_difference -> { Instruction.count }, 1 do
        ChatRespondJob.perform_now(confirm_msg.id)
      end
    end

    new_instruction = @project.instructions.where.not(id: @prior_instruction.id).order(:id).last
    assert_equal "implementing", new_instruction.phase
    assert_equal "Change the top banner to green.", new_instruction.description
    assert_equal 1, new_instruction.revisions.count, "a tweak must produce a single revision, not a rebuild"
    assert_equal "Update banner color in application layout", new_instruction.revisions.first.summary
  end

  test "instruction.completed enqueues an auto-recap ChatRespondJob" do
    new_instruction = @project.instructions.create!(
      user_intent: "make the banner green", description: "Change banner color",
      phase: :implementing,
      anchor_message: @chat.messages.create!(role: :user, content: "make the banner green")
    )

    assert_enqueued_jobs 1, only: ChatRespondJob do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: new_instruction.id
      )
    end

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_includes nudge.content, "Auto-resume"
  end

  private

  def fake_planner_returning(result)
    Module.new.tap do |m|
      m.define_singleton_method(:call) { |**| result }
    end
  end

  # Stub helper: drives RubyLLM Chat#complete through scripted turns.
  # The exact API surface depends on how RubyLLM exposes `complete`.
  # The contract: each call to chat.complete consumes one entry from
  # scripted_turns and applies its effects (streaming text content and/or
  # invoking tools through the agent's tool registry).
  def with_chat_complete_stub(scripted_turns:)
    # Implementation detail — pseudocode. The actual stub may need to:
    # - swap GeneratorAgent.complete via define_singleton_method
    # - synthesize tool_call records for the tool_call entries
    # - synthesize streaming text for the text entries
    #
    # See test/integration/generate_todo_list_test.rb for the existing
    # stub pattern and adapt that here. If that pattern doesn't cover
    # multi-turn scripts, extend it locally in this test.
    raise NotImplementedError, "adapt from test/integration/generate_todo_list_test.rb"
    yield
  end
end
```

The `with_chat_complete_stub` body is left as a guided NotImplementedError because the existing stub pattern in `generate_todo_list_test.rb` is the source of truth — the implementer should adapt it for multi-turn scripted behavior. The key contract: turn 1 produces text-only (no tool call); turn 2 produces a `modify_application` tool call.

#### 3. Document the test in the plan tracker
Add an entry pointing to the new test in `docs/03-plans/` if a Phase tracker doc exists for the chat-agent area. (Optional — only if such a tracker exists today.)

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test test/integration/modify_application_after_completion_test.rb` — green
- [ ] `bin/rails test` — full suite green
- [ ] No `Roast` subprocess kicked off during the test (integration test stays in-memory; verify via `Process.spawn` count or by ensuring tests run in <5 s)

#### Manual Verification:
- [ ] None at this phase — pure automated test. Bugs A/B/C have been manually verified in Phases 5, 7, 8.

**Implementation Note**: at this point, all three bugs have automated and manual verification. Run a final full-stack smoke (combined run of Phases 5+7+8 manual steps on a fresh project + a tweak project) before declaring the plan complete.

---

## Testing strategy

### Unit tests (per-phase)
- Phase 1: existing `PlanApplicationCreation` tests (renamed from `CreatePlan`).
- Phase 2: existing `CreateApplication` tests (renamed from `StartGeneration`).
- Phase 3: new `PlanApplicationModification` tests (façade + AdHocLLM adapter), mirroring the existing pattern.
- Phase 4: new `ModifyApplication` tool tests (mirror of `CreateApplication` test suite, with single-revision and multi-revision plan cases).
- Phase 5: new `GeneratorAgent` tests covering tool-surface gating.
- Phase 7: extended `EventSubscribersTest` covering the new `🌀 Building` subscriber.
- Phase 8: extended `EventSubscribersTest` + new `MessageTest` for `system_injected` visibility.

### Integration tests
- Phase 5: existing `generate_todo_list_test.rb` continues to verify the create_application path end-to-end (gated by `E2E_GENERATE`).
- Phase 9: new `modify_application_after_completion_test.rb` verifies the modification path with stubbed LLM + planner (no gate, runs in CI).

### Manual smoke (per phase)
Each phase pauses for manual verification before the next phase merges. Bug A in Phase 5, Bug B in Phase 7, Bug C in Phase 8.

### What we deliberately don't test
- **Real-Haiku prompt behavior**. Whether the LLM actually obeys the confirmation-first rule and the no-text-after-tool rule depends on Haiku's training. Verifying this requires a paid API call and is flaky. We rely on manual smoke for behavioral verification.
- **Roast workflow**. Already covered by `generate_todo_list_test.rb` and `phase-3 preview-isolation` integration tests.
- **The `current_state_prompt` text exactly**. The text is part of the prompt; testing exact strings would couple the test to prompt rephrasing. We test the structural fact ("STATE A vs STATE B is selected based on instruction phase") via prompt-content sanity checks rather than full string matching.

## References

### Code (current state)
- `app/agents/generator_agent.rb` — agent + tool binding (Phase 5)
- `app/tools/start_generation.rb` — current sole entry point (Phase 2 rename target)
- `app/tools/suggest_prompts.rb` — pattern for project-scoped tool with broadcast
- `app/services/create_plan.rb` — Phase 1 rename target
- `app/services/create_plan/ad_hoc_llm.rb` — Phase 1 rename target
- `app/prompts/generator_agent/instructions.txt.erb` — agent system prompt (Phases 5, 6, 7)
- `app/prompts/create_plan_system.md` — planner system prompt (Phase 1 rename + Phase 3 mirror)
- `app/models/project.rb#current_state_prompt:45-54` — runtime-state injection (Phase 6 update)
- `app/models/message.rb` — visibility helper + broadcasts (Phase 8 update)
- `app/models/instruction.rb` — phases enum (untouched)
- `app/jobs/chat_respond_job.rb` — drives one LLM turn (Phase 8 reuses unchanged)
- `config/initializers/event_subscribers.rb` — bus wiring (Phases 7, 8 add subscribers)
- `app/schemas/plan_schema.rb` — shared schema (untouched)

### Code (reference implementations)
- `spikes/roast/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `spikes/roast/findings.md` — Phase 1 lessons learned
- `app/jobs/execute_instruction_job.rb` — runs revisions for an Instruction (untouched)

### Documents
- Research: `thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md`
- Prior idea sketch: `docs/09-ideas/02-deferred-request-handling.md` (2026-04-22, Bug C analysis with four candidate solutions)
- Templates plan whose smoke surfaced these bugs: `thoughts/shared/plans/2026-05-02/randomized-design-systems-for-generated-apps.md`

### Memory entries that constrained design
- `feedback_test_branch_coverage` — automated tests are never optional; one test per logical branch
- `feedback_state_by_absence` — encode satisfied gates by deleting the gate; relevant for `current_state_prompt` simplification
- `feedback_no_thoughts_sync` — never run thoughts-sync at end of skills
- `feedback_no_service_objects` — applies to greenfield; we extend existing `app/services/` pattern
- `project_ruby_llm_partial_path` — RubyLLM messages override `to_partial_path`; explicit partial when broadcasting
- `project_dev_cable_solid` — dev cable.yml uses solid_cable so subscriber broadcasts reach the browser
- `project_ruby_llm_complete_vs_ask` — `chat.complete` (not `ask`) when user message is already persisted
- `project_form_replace_over_redirect` — Turbo-submitted form pattern
- `project_ruby_llm_chat_api` — Chat#complete takes only a block
- `project_ruby_llm_message_lifecycle` — tool_calls attach AFTER `message.save!`
