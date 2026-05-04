---
date: 2026-05-04
author: Paweł Strzałkowski
branch: randomized-design-systems
status: ready-for-implementation
related_research: thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md
related_ideas: docs/09-ideas/02-deferred-request-handling.md
---

# Chat-agent: design-tweak rebootstrap, premature "Done!", deferred follow-up — Overview

This is the index for a 9-phase plan. Each phase is one atomic commit and lives in its own file. Read this overview for context, then load the phase file for the work you're about to do.

## Phase index

| # | File | Commit subject | Bug fix |
|---|---|---|---|
| 1 | [`01-rename-create-plan.md`](01-rename-create-plan.md) | `chat-agent: rename CreatePlan to PlanApplicationCreation` | — |
| 2 | [`02-rename-start-generation.md`](02-rename-start-generation.md) | `chat-agent: rename start_generation tool to create_application` | — |
| 3 | [`03-add-modification-planner.md`](03-add-modification-planner.md) | `chat-agent: add PlanApplicationModification planner` | — |
| 4 | [`04-add-modify-application-tool.md`](04-add-modify-application-tool.md) | `chat-agent: add ModifyApplication tool` | — |
| 5 | [`05-gate-tool-surface.md`](05-gate-tool-surface.md) | `chat-agent: bind one mutation tool per workspace state` | **Bug A** |
| 6 | [`06-confirmation-first-prompt.md`](06-confirmation-first-prompt.md) | `chat-agent: require user confirmation before mutation tools` | — |
| 7 | [`07-system-emitted-starting-message.md`](07-system-emitted-starting-message.md) | `chat-agent: emit '🌀 Building…' as system message after generation starts` | **Bug B** |
| 8 | [`08-auto-recap-subscriber.md`](08-auto-recap-subscriber.md) | `chat-agent: auto-recap and prompt user after generation finishes` | **Bug C** |
| 9 | [`09-integration-test.md`](09-integration-test.md) | `chat-agent: integration test for modify_application happy path` | — |

Phases 1-2 are mechanical renames. Phases 3-4 add new code that isn't yet wired. Phase 5 wires it; Bug A goes away here. Phases 6-7 fix Bug B. Phase 8 fixes Bug C. Phase 9 adds the regression test that ties it together.

After each phase: pause for manual confirmation that automated verification + manual smoke pass before proceeding.

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
