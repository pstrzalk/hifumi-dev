---
date: 2026-05-04T16:04:56Z
researcher: Paweł Strzałkowski
git_commit: efe4074afcc9c375770c790af941cd7007bb271a
branch: randomized-design-systems
repository: pstrzalk/rails-app-generator
topic: "Chat-agent bugs surfaced during Phase 4/5 manual smoke: design-tweak rebootstrap, premature 'Done!' reply, deferred follow-up dropped on the floor"
tags: [research, chat-agent, generator-agent, start-generation, create-plan, deferred-requests, instructions-prompt]
status: complete
last_updated: 2026-05-04
last_updated_by: Paweł Strzałkowski
---

# Research: Chat-agent design-tweak rebootstrap, premature "Done!" reply, and deferred follow-up dropped

**Date**: 2026-05-04T16:04:56Z
**Researcher**: Paweł Strzałkowski
**Git Commit**: `efe4074afcc9c375770c790af941cd7007bb271a` (no commits yet on `randomized-design-systems` — templates Phase 1-5 working-tree only)
**Branch**: `randomized-design-systems`
**Repository**: `pstrzalk/rails-app-generator`

## Research Question

Document three chat-agent behavior bugs surfaced during the manual end-to-end smoke of the templates plan (`thoughts/shared/plans/2026-05-02/randomized-design-systems-for-generated-apps.md`), so a follow-up plan-creation session has the backstory, evidence, and code map needed to write a fix plan.

## Backstory

The templates plan adds five frontend templates (cyber, flower, earth, office, kids), an LLM picker, manifest+rules wiring, and `update_docs` scope extension. Phases 1-3 were verified by automated tests and a live Haiku smoke. Phases 4 and 5 require a real generation against an existing project to verify (a) the implementer reads `frontend.md` from the manifest and (b) `update_docs` keeps `frontend.md` in sync.

Manual smoke run on Project #9 ("children's storybook"):

1. ~12:48 — original instruction #9 created via `start_generation`. `CreatePlan` produced 6 revisions (#41-#46). The kids template was picked (correct match for "children's storybook"). Revisions completed by 13:03:59 ([log line 6762](#evidence)).
2. 13:17:02 — user sends a *design tweak*: `make the make the primary color teal`.
3. 13:17:04 — chat agent emits a `start_generation` tool call rather than e.g. queueing a single styling revision. The `intent:` argument is the FULL original project intent with `Primary color is teal.` appended; `clarifications:` is `{"primary_color":"teal"}`.
4. 13:17:14 — a brand-new instruction is created with `phase: implementing`, project_id=9, with a kids-themed teal plan ([log line 7568](#evidence)). This instruction got revisions #47-#52 — full app rebuild.
5. 13:17:15 — assistant text streams to completion: `"Done! Updated the app with a beautiful teal color scheme throughout the interface. Everything should feel cohesive and delightful now."` This lands ~13 seconds after the user message — too fast for an actual generation, which then takes minutes.
6. 13:19:08 — user follows up with `make to top banner green, not yellow`. The rebuild instruction is still in `implementing`. The chat agent emits an assistant text reply deferring (`"I'll make that change once the current build finishes…"`) **with no `tool_calls`**. The follow-up never enters any queue.
7. ~13:31 — rebuild instruction completes ([log line 13547](#evidence)). Banner remains yellow because the green-banner request was never converted into a revision.

Side effect of the rebuild path: the original Story scaffold (#41) created `rating_count` as a real DB column. The rebuild's #47 generated a different Story scaffold. When the user restarted the preview mid-rebuild, the running container observed an inconsistent transitional state — `Story` ActiveRecord model not finding `rating_count`. This is collateral, not a separate bug; it's caused by the rebuild itself (Bug A).

## Summary

There are three distinct chat-agent behaviors at play, all rooted in the system prompt + tool surface in `app/prompts/generator_agent/instructions.txt.erb` + `app/tools/start_generation.rb` + `app/models/project.rb#current_state_prompt`. The data layer (`Instruction` phases, `StartGeneration` in-progress guard) is internally consistent; the model-driven layer is what produces the user-visible bugs.

- **Bug A — design-tweak rebootstrap**. The agent has only one big hammer (`start_generation`), and the prompt's only steering signal is "is something running right now?". A design tweak after a completed build looks identical to a fresh project and goes through the same path: re-synthesize the full intent → `CreatePlan` → 3-6 fresh revisions.
- **Bug B — premature "Done!"**. The prompt instructs the agent to "summarise what you started in 1-2 sentences" *after* `start_generation` returns. The model interprets that as room to claim completion (`"Done! Updated…"`). Streamed and persisted as the assistant message body before any code has been generated.
- **Bug C — deferred follow-up dropped on the floor**. While an instruction is non-terminal, `current_state_prompt` injects a system-prompt line saying "Do NOT call `start_generation` now" + "Do NOT claim any new work has been done". The agent obeys by replying in plain text — and there is no tool, queue, or persistence path to capture the user's pending request. When the build finishes, nothing resumes it.

## Detailed Findings

### Bug A — `start_generation` is the only hammer; design tweaks rebootstrap the project

**Severity**: 🔴 high. End-user impact: a one-line design request can rebuild the app from scratch (5-10 min, dollars in tokens), can change DB schema between runs, and can cause running-preview crashes (`missing attribute 'rating_count' for Story`).

**Current behavior** ([`app/prompts/generator_agent/instructions.txt.erb:1-13`](../../../../app/prompts/generator_agent/instructions.txt.erb)):

> "When the user's intent is clear enough to start, call the `start_generation` tool. Pass `intent:` as a plain-language description of what they want…"

The prompt knows two states only — "running" vs "not running" — via the runtime line injected by [`Project#current_state_prompt`](../../../../app/models/project.rb#L45-L54). Both states say "call `start_generation` if the user wants to build *or change* something" / "Do NOT call". There is no third path: "the project already exists; this looks like a tweak; do something smaller."

The toolset confirms it: only two tools are bound to the agent ([`app/agents/generator_agent.rb:6-11`](../../../../app/agents/generator_agent.rb)) — `StartGeneration` and `SuggestPrompts`. There is no `RequestRevision` / `AddRevision` / `ContinueGeneration` tool.

`StartGeneration#execute` ([`app/tools/start_generation.rb:19-67`](../../../../app/tools/start_generation.rb)) creates a fresh `Instruction` row regardless of whether the project already has completed instructions:

```ruby
instruction = @project.instructions.create!(
  user_intent: intent,
  description: result.instruction_description,
  phase: :implementing,
  anchor_message: anchor_message
)
```

It also delegates to `CreatePlan.call` ([`app/services/create_plan/ad_hoc_llm.rb:8-12`](../../../../app/services/create_plan/ad_hoc_llm.rb)), whose system prompt ([`app/prompts/create_plan_system.md:3-4`](../../../../app/prompts/create_plan_system.md)) hard-codes:

> "3 to 6 revisions. Each revision is one atomic, testable change."

There is no notion of "this is a tweak — emit 1 revision, scoped to the change". `CreatePlan` is symmetric for fresh starts and follow-ups.

**Concrete log evidence** (`tmp/local_test_story_garden.log`):

- **Line 7185**: user message id created with content `make the make the primary color teal` at `2026-05-04 13:17:02`.
- **Line 7431**: `start_generation` tool call args persisted as `{"intent":"Children's storybook where visitors can add and read stories without accounts. Main page shows a link to create a story plus a list of existing stories with 2-line previews and 1-5 star ratings. Visitors can rate any story. Very beautiful, delightful UI focused on making it fun for children. Primary color is teal.","clarifications":{"primary_color":"teal"}}`. Note the bracketed sentence — the original intent re-emitted, with the design tweak appended.
- **Line 7568**: `Instruction Create … VALUES (103, '2026-05-04 13:17:14.325557', 'Build a public children's storybook app where visitors can create stories, read them with previews, and rate them 1-5 stars with a delightful, child-friendly teal-themed UI.', 'implementing', 9, NULL, …)`. New instruction, project_id=9, phase=implementing.
- **Lines 1010, 2653, 3437, 3873, 4417, 5439** (Roast `[W2.1]` log starts inside the rebuild's roast subprocesses): revisions #47-#52 with summaries like "Generate Story scaffold with title, content, and ratings aggregation", "Add Rating model", "Set stories index as root path with beautiful preview cards and teal theme", "Build story creation and display", "Add inline rating UI", "Enhance index page". All six revisions exist solely because the agent treated the tweak as a fresh project.
- **Line 6762**: `UPDATE "instructions" SET "phase" = 'completed' … WHERE "instructions"."id" = 9 … 13:03:59`. Original instruction had been completed for ~13 minutes when the teal tweak landed — `current_state_prompt` was therefore on the "MAY call `start_generation`" branch.

**Schema-drift collateral**: original revision #41 generated `rails generate scaffold Story title:string content:text average_rating:float rating_count:integer 2>&1` (line ~2594 of the log earlier in this research). Rebuild revision #47 generated a *different* Story scaffold with `ratings aggregation` semantics. Restarting the preview between the two states surfaces `missing attribute 'rating_count' for Story` against the running container's now-stale view code.

### Bug B — Premature "Done!" reply emitted alongside `start_generation`

**Severity**: 🟡 medium. End-user impact: confusing UX — user thinks the change is live, doesn't realize a multi-minute generation just kicked off.

**Current behavior** ([`app/prompts/generator_agent/instructions.txt.erb:7`](../../../../app/prompts/generator_agent/instructions.txt.erb)):

> "After `start_generation` returns, summarise what you started in 1-2 sentences, and then call the `suggest_prompts` tool with 3-5 natural next steps the user might want…"

The prompt says "summarise what you *started*" (present perfect, indicating begin-state). The model in practice produces past-tense completion language: `"Done! Updated the app with a beautiful teal color scheme…"`. The streaming machinery in `ChatRespondJob` ([`app/jobs/chat_respond_job.rb:16-25`](../../../../app/jobs/chat_respond_job.rb)) writes each chunk into the assistant message's `content` column without any post-validation, so the bogus "Done" persists into chat history.

`Project#current_state_prompt` *does* contain explicit anti-claim guidance — but only in the `running` branch:

> "Do NOT claim any new work has been done — it hasn't. Tell the user you'll start new changes once the current build finishes." ([`app/models/project.rb:53`](../../../../app/models/project.rb#L53))

The "no generation running" branch has no such guard:

> "No generation is currently running. You MAY call `start_generation` if the user wants to build or change something." ([`app/models/project.rb:49`](../../../../app/models/project.rb#L49))

So when `start_generation` succeeds, the system prompt for that very turn was the "you MAY call" branch — no anti-claim language. After the tool returns, the LLM continues the same turn and emits its summary text without the runtime-state guidance updating mid-turn.

There is also no UI affordance separating "build kicked off" from "build finished" in the assistant message stream. The `✅ Generation finished.` indicator (per [`docs/09-ideas/02-deferred-request-handling.md`](../../../../docs/09-ideas/02-deferred-request-handling.md)) fires from a different event path (`instruction.completed` notification → presumably another assistant message), so an LLM-claimed "Done!" and the system-emitted "✅ Generation finished." can both appear, the first lying.

**Concrete log evidence** (`tmp/local_test_story_garden.log`):

- **Line 7185**: user message at `2026-05-04 13:17:02.655856`.
- **Line 7431**: `start_generation` tool call written at `2026-05-04 13:17:04.660892`.
- **Line 7967**: `UPDATE "messages" SET … "content" = 'Done! Updated the app with a beautiful teal color scheme throughout the interface. Everything should feel cohesive and delightful now.' … WHERE "messages"."id" = 106 … 13:17:15.981449`. Streamed in the same `ChatRespondJob` invocation (`208ee8cb-4dc4-4251-b939-1ae1fe138494`) as the start_generation call.
- Time delta: 13.3 s between user message and final assistant content. A real revision takes 30-90 s for codegen alone; a 6-revision instruction takes 5-10 min. The "Done!" cannot be referencing actual completion.

### Bug C — Deferred follow-up dropped without persistence

**Severity**: 🟡 medium. End-user impact: requests typed during a build are silently lost. Per [`docs/09-ideas/02-deferred-request-handling.md`](../../../../docs/09-ideas/02-deferred-request-handling.md), this was observed and deferred during Phase 2 Step 6 manual verification (2026-04-22), but never resolved.

**Current behavior**: `Project#current_state_prompt` ([`app/models/project.rb:45-54`](../../../../app/models/project.rb#L45-L54)) injects different runtime guidance per turn depending on whether any non-terminal instruction exists:

```ruby
active = instructions.where.not(phase: %w[completed failed cancelled]).order(:created_at).last
return "No generation is currently running. You MAY call `start_generation` …" unless active
total = active.revisions.count
done  = active.revisions.where(status: :completed).count
"A generation is CURRENTLY RUNNING (instruction ##{active.id}, #{done}/#{total} revisions complete). Do NOT call `start_generation` now. Do NOT claim any new work has been done — it hasn't. Tell the user you'll start new changes once the current build finishes."
```

The prompt obediently emits a plain-text deferral. There is no tool to call to *persist* the request: no `QueueRevision`, no draft/pending instruction model, no UI affordance. The `Instruction` enum ([`app/models/instruction.rb:6-13`](../../../../app/models/instruction.rb)) doesn't include `pending` / `queued` / `awaiting_predecessor` — only `researching`, `planning`, `implementing`, `completed`, `failed`, `cancelled`. The set of phases excluded from "active" by `current_state_prompt` is `%w[completed failed cancelled]` — same set as `StartGeneration`'s in-progress guard ([`app/tools/start_generation.rb:20`](../../../../app/tools/start_generation.rb#L20)).

When the active instruction transitions to a terminal phase, nothing fires that consults the prior chat history for "did the user ask for something while we were busy". `instruction.completed` notifications are wired only to status broadcasts, not to a chat-resume hook.

**Concrete log evidence** (`tmp/local_test_story_garden.log`):

- **Line 8749**: user message id created with content `make to top banner green, not yellow` at `2026-05-04 13:19:08`.
- The rebuild instruction (created 13:17:14, ~5 minutes earlier) was still in `implementing` at this moment. `current_state_prompt` returned the "CURRENTLY RUNNING" branch.
- The `ChatRespondJob` that processed message 107 produced an assistant reply with **no `tool_calls`** — only plain text in the deferral language. (See the absence of any `start_generation` tool call between the user message and the next instruction-completion event.)
- **Line 13547**: rebuild instruction completes at `2026-05-04 13:31:30`. No subsequent `start_generation` tool call references "banner green". User confirmed in conversation: final state has teal applied (from the rebuild) but banner remains yellow (deferred request lost).

Existing analysis of this bug + four solution sketches (LLM-side resume / UI-side queue card / reject-mid-run / hybrid LLM-summary + UI queue) lives in [`docs/09-ideas/02-deferred-request-handling.md`](../../../../docs/09-ideas/02-deferred-request-handling.md). That doc was written 2026-04-22 and explicitly deferred resolution.

## Code References

### Files most likely involved in a fix

- [`app/prompts/generator_agent/instructions.txt.erb`](../../../../app/prompts/generator_agent/instructions.txt.erb) — chat agent system prompt. Decides when to call `start_generation`, what to say after, and how to handle in-flight follow-ups.
- [`app/agents/generator_agent.rb`](../../../../app/agents/generator_agent.rb) — `RubyLLM::Agent` subclass; instantiates the prompt and the tool list. Adding a `RequestRevision` / `QueueRevision` tool happens here.
- [`app/tools/start_generation.rb`](../../../../app/tools/start_generation.rb) — current sole entry point for new work; in-progress guard at line 20-24 returns an error string the LLM is supposed to render to the user (but doesn't reach because the prompt steers the agent away from calling at all when running).
- [`app/tools/suggest_prompts.rb`](../../../../app/tools/suggest_prompts.rb) — second tool. Pattern of a simple project-scoped tool that emits a Turbo broadcast — useful as a template if a new `QueueRevision` tool is added.
- [`app/models/project.rb:45-54`](../../../../app/models/project.rb#L45-L54) (`current_state_prompt`) — runtime-state language injected into the system prompt every turn.
- [`app/models/instruction.rb:6-13`](../../../../app/models/instruction.rb) — `phase` enum. Currently no `pending` / `queued` state.
- [`app/services/create_plan.rb`](../../../../app/services/create_plan.rb) and [`app/services/create_plan/ad_hoc_llm.rb`](../../../../app/services/create_plan/ad_hoc_llm.rb) — generates 3-6 revisions per intent. A "tweak" path likely needs either a different planner or a planner mode flag.
- [`app/prompts/create_plan_system.md:3`](../../../../app/prompts/create_plan_system.md#L3) — hard-codes "3 to 6 revisions". Tweak mode would override this.
- [`app/jobs/chat_respond_job.rb`](../../../../app/jobs/chat_respond_job.rb) — drives the LLM turn that streams "Done!" content. No post-tool-call mutation hook.
- [`app/schemas/plan_schema.rb`](../../../../app/schemas/plan_schema.rb) — JSON shape `CreatePlan` enforces. May need a new `mode: "tweak" | "fresh"` field if the planner branches.

### Log evidence (absolute lines, `tmp/local_test_story_garden.log`)

| Line     | Event                                                                                                                                |
|----------|--------------------------------------------------------------------------------------------------------------------------------------|
| 1639     | First `start_generation` tool call (initial project bootstrap, 12:48:19)                                                             |
| 1759     | First instruction (#9) created, phase=implementing                                                                                   |
| 6762     | Instruction #9 transitions to `completed` at 13:03:59                                                                                |
| 7177     | HTTP POST: user types "make the make the primary color teal" (13:17:02)                                                              |
| 7185     | User Message row inserted                                                                                                            |
| 7431     | Second `start_generation` tool call args persisted (FULL intent + "Primary color is teal." appended) at 13:17:04                     |
| 7568     | Second instruction created with kids-themed teal description, project_id=9, phase=implementing, at 13:17:14                          |
| 7967     | Streaming finishes: assistant content = `"Done! Updated the app with a beautiful teal color scheme…"` at 13:17:15 (13s after user)   |
| 1010 / 2653 / 3437 / 3873 / 4417 / 5439 | Roast `[W2.1]` headers for revisions #47-#52 (rebuild, full app re-implementation)                                |
| 8741     | HTTP POST: user types "make to top banner green, not yellow" (13:19:08)                                                              |
| 8749     | User Message row inserted (id=107 per Turbo broadcast at 8793)                                                                       |
| 13547    | Rebuild instruction transitions to `completed` at 13:31:30 (banner-green request never converted into a revision)                    |

## Architecture Documentation

### Chat-driven generation flow as it exists today

1. User types into the chat panel; controller persists a `Message(role: :user)` and enqueues `ChatRespondJob.perform_later(message_id)`.
2. `ChatRespondJob` ([`app/jobs/chat_respond_job.rb:11-25`](../../../../app/jobs/chat_respond_job.rb#L11-L25)) hydrates a `RubyLLM` context with the project owner's OpenRouter key, fetches the `GeneratorAgent` for the chat, and calls `agent.with_context(ctx).complete { |chunk| … }`. Each streamed chunk is appended to the latest assistant message's `content` and broadcast via Turbo.
3. `GeneratorAgent` ([`app/agents/generator_agent.rb`](../../../../app/agents/generator_agent.rb)) is a `RubyLLM::Agent` subclass that:
   - uses model `anthropic/claude-haiku-4.5`
   - loads its instructions from `app/prompts/generator_agent/instructions.txt.erb` with `current_state` interpolated
   - exposes two tools: `StartGeneration` and `SuggestPrompts`.
4. `Project#current_state_prompt` ([`app/models/project.rb:45-54`](../../../../app/models/project.rb#L45-L54)) recomputes runtime guidance on every turn-build. It looks at the project's `instructions` and chooses one of two strings.
5. If the LLM emits a `start_generation` tool call:
   - `StartGeneration#execute` ([`app/tools/start_generation.rb:19-67`](../../../../app/tools/start_generation.rb#L19-L67)) checks `where.not(phase: %w[completed failed cancelled]).exists?`. If true, returns `{ error: "A generation is already in progress…" }` (the LLM is supposed to relay this; in practice the prompt guidance prevents the model from calling the tool at all when running).
   - Otherwise it calls `CreatePlan.call(intent:, clarifications:, context:, openrouter_api_key:)`, transactionally creates an `Instruction(phase: :implementing)` plus N `Revision` rows, and instruments `instruction.requested`.
6. `instruction.requested` is consumed elsewhere (event-bus initializer) to enqueue `ExecuteInstructionJob` on the `generation` queue.

### `CreatePlan` shape

`CreatePlan` is a thin façade ([`app/services/create_plan.rb`](../../../../app/services/create_plan.rb)) that delegates to the configurable `implementation` (`AdHocLLM` in production, `PlanFixtures` in `bin/generate full` smoke). The default implementation invokes Haiku with [`app/prompts/create_plan_system.md`](../../../../app/prompts/create_plan_system.md) as system prompt and [`app/schemas/plan_schema.rb`](../../../../app/schemas/plan_schema.rb) as the structured-output schema. Output is `instruction_description: String` + `revisions: [{summary, prompt}, …]` of length 3-6.

### `Instruction` lifecycle

Phases: `researching → planning → implementing → completed` (or `failed` / `cancelled`). Two of these (`researching`, `planning`) are unused in the current code path — `StartGeneration` jumps straight to `implementing`. Terminal set used by both `current_state_prompt` and `StartGeneration` guard: `%w[completed failed cancelled]`.

## Historical Context (from thoughts/)

- [`docs/09-ideas/02-deferred-request-handling.md`](../../../../docs/09-ideas/02-deferred-request-handling.md) — written 2026-04-22 during Phase 2 Step 6 manual verification. Lays out four candidate solutions (A-D) for Bug C: LLM-side resume kick after completion, UI-side queue card, reject-mid-run controller-level, hybrid LLM-summary + UI queue. Explicitly deferred at the time pending UI work or a second confirmation of the same friction. This research provides that second confirmation, plus the additional Bug A/Bug B context.
- Memory `project_deferred_research_tracks.md` — sequencing: docs/knowledge-mgmt and prompt-injection were the only two deferred research tracks the user wanted to revisit explicitly. The chat-agent/UX bugs documented here are a *third* track, surfaced from the Phase 4/5 templates smoke.
- `thoughts/shared/plans/2026-05-02/randomized-design-systems-for-generated-apps.md` — the templates plan whose manual verification surfaced these bugs. Phases 1-5 are working-tree-implemented on this branch but uncommitted; the rebuild path the agent triggered actually exercised Phase 4's manifest+rules wiring (Project #9's revision #49 `app/views/stories/index.html.erb` uses kids-template signature classes `bg-[#7C3AED]`, `border-2 border-[#1A1A1A]`, `shadow-[6px_6px_0_#1A1A1A]`, `rounded-2xl` directly out of [`lib/templates/kids/frontend.md`](../../../../lib/templates/kids/frontend.md)). So the templates plan itself is verified working — these bugs are independent.

## Open Questions for the planner

These need answers before a fix plan can be written.

### Q1 — Single-tool-with-mode, or two distinct tools?

`StartGeneration` is the only "do work" tool today. Two shapes are possible:

- **(a) Mode flag on the existing tool**: add `mode: "fresh" | "tweak"` (or `scope: "project" | "revision"`). Tool branches: fresh-mode preserves today's behavior; tweak-mode skips `CreatePlan`'s 3-6-revision shape and adds a single `Revision` to the most recent `Instruction` (or creates a small follow-up `Instruction`).
- **(b) Two separate tools**: `start_generation` (fresh project bootstrap) and a new `request_revision` (single-revision tweak). Each has narrower description text; the LLM picks based on prompt language. Requires updating the agent's tool array in `GeneratorAgent` and the system prompt.

Which surface forces the LLM to make the right choice more reliably? Tooling shape implications — adding a `RubyLLM::Tool` in `app/tools/` follows the same pattern as `SuggestPrompts` ([`app/tools/suggest_prompts.rb`](../../../../app/tools/suggest_prompts.rb)).

### Q2 — Where do tweak revisions live? New instruction vs. appended-to-last?

A "make the primary color teal" revision could:

- **(a)** create a brand-new `Instruction(phase: :implementing)` with a single `Revision`. Same lifecycle, smaller payload. UI/state reasoning stays simple.
- **(b)** append a `Revision` to the most recent completed `Instruction`. The instruction's `phase` would need to flip from `completed` back to `implementing`. New phase? New transitions?

Option (a) is operationally simpler. Option (b) keeps history more linear ("this all belonged to one user-initiated request", though the user likely thinks of these as separate). What's the right model for "instruction = one user message" vs "instruction = one logical chunk of work"?

### Q3 — Should `CreatePlan` itself learn a "tweak" mode, or is the tweak path planner-free?

Two approaches:

- **(a) Planner-free tweak**: skip `CreatePlan` entirely; the tool turns the user's prompt directly into a single `Revision` with `summary` = the user's intent and `prompt` = the user's message verbatim (or lightly rewritten). Ships fastest. Risk: the W2 implementer is asked to act on a vague human prompt without `CreatePlan`'s structuring.
- **(b) `CreatePlan` mode flag**: extend [`app/prompts/create_plan_system.md`](../../../../app/prompts/create_plan_system.md) and [`app/schemas/plan_schema.rb`](../../../../app/schemas/plan_schema.rb) with a "single-revision tweak" mode that emits exactly one revision, prompt phrased file-level as today. Slightly slower (extra LLM call) but quality stays consistent.

Cost trade-off: another Haiku call (~$0.001) vs. risk of W2 receiving a malformed prompt.

### Q4 — Premature "Done!" — fix in prompt, or fix in tool-result-driven response?

Current prompt says "summarise what you started in 1-2 sentences". The model interprets that loosely.

- **(a) Tighten the prompt**: replace with explicit imperative + forbidden words. E.g. "After `start_generation` returns, write 1-2 sentences using future-tense or progress language. Forbidden words: 'Done', 'Updated', 'Finished', 'Complete', 'Now'. Example: 'Starting your update — I'll add task completion next.'" Cheap, may still leak through under model noise.
- **(b) Replace the post-tool summary with a structured echo**: don't let the LLM produce free text after `start_generation`. Instead the tool itself returns a string the system displays (e.g. `"🌀 Starting: <instruction_description>"`); the agent is instructed to write nothing after the tool. The `instruction.completed` notification path then writes the only completion message. Requires updating the prompt + the tool's return shape.
- **(c) Add a runtime guard line for the post-start branch**: extend `Project#current_state_prompt` to detect "we're in the same turn that just called `start_generation`" and inject anti-claim language. Tricky — `current_state_prompt` is computed turn-build-time, not mid-turn.

### Q5 — Deferred handling — pick one of `02-deferred-request-handling.md`'s options, or something hybrid

The 2026-04-22 idea doc enumerated four candidates. A planner needs to pick:

- **(A) LLM-side kick** post-completion. Risk: re-triggers stale requests; needs bounded scope ("only the most recent user message after the last `start_generation`").
- **(B) UI-side queue card** with a "start now" button after completion. Adds new persistent state.
- **(C) Reject mid-run** at the controller level. Worst UX.
- **(D) Hybrid** — LLM emits a `QueueRequest` tool call mid-run with a structured summary; UI shows a card; user clicks to fire `start_generation` after completion.

The natural fit if Q1 lands as a separate `request_revision` tool: option (D) — `QueueRequest` becomes a thin wrapper that creates a draft `Revision` row plus a UI affordance, and clicking "start now" or auto-firing on `instruction.completed` invokes `request_revision` with the queued payload. But does that work without a new `Revision` status (`queued` / `pending_user_approval`)?

### Q6 — How to test all this

The current test surface for the chat agent is light — there's no `test/agents/generator_agent_test.rb`, no integration test that drives a full chat-respond → start_generation → execute round-trip with deterministic stubs. The templates plan's Phase 3 added stub patterns ([`with_picker_call_stub`](../../../../test/jobs/execute_instruction_job_test.rb) using singleton-method-swap due to Minitest 6 dropping `Object#stub`).

The fix plan needs a testing strategy:
- Stub `RubyLLM` chat completion to drive the agent through scripted tool calls
- Assert what tool calls fire for "design tweak" prompts vs "fresh project" prompts
- Assert what the assistant message body says after `start_generation` returns
- Assert the deferred-request → resumed-request flow end-to-end

### Q7 — Does the schema-drift collateral need a separate fix?

Bug A's symptom — `missing attribute 'rating_count'` mid-rebuild — is caused by schema regen between original and rebuild. If Bug A is fixed (no more rebuilds), this collateral disappears. But there's a *second*, latent issue: the preview container's running Rails app is not invalidated when the workspace HEAD moves under it. Fix-plan question: should `instruction.requested` automatically stop the preview before any new revision (already done per `phase_3` plan) AND stop it from being restarted while the new instruction is in-flight? (Today the user manually restarted the preview during the rebuild.) Likely a small gate in [`app/jobs/start_preview_job.rb`](../../../../app/jobs/start_preview_job.rb) — out of scope for the chat-agent fix proper, but worth flagging.

## Related Research

- [`thoughts/shared/research/2026-05-02/design-systems-randomized-application.md`](../../research/2026-05-02/design-systems-randomized-application.md) — research that produced the templates plan, whose manual smoke surfaced these bugs.
- [`thoughts/shared/plans/2026-05-02/randomized-design-systems-for-generated-apps.md`](../../plans/2026-05-02/randomized-design-systems-for-generated-apps.md) — templates plan, Phases 1-5 implemented working-tree on this branch.
- [`docs/09-ideas/02-deferred-request-handling.md`](../../../../docs/09-ideas/02-deferred-request-handling.md) — original sketch of Bug C and four candidate fixes.

## Open Questions

The Q1-Q7 list above is the planner's input. Once those are answered, a phased plan can be written along the lines of:

1. New tool surface (Q1 + Q2 + Q3)
2. Prompt tightening + post-`start_generation` reply discipline (Q4)
3. Deferred-request capture path (Q5)
4. Test harness for the chat-agent flow (Q6)
5. Optional: preview-isolation gate during in-flight instructions (Q7)
