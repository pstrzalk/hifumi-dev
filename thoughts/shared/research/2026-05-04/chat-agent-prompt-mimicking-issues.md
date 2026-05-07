---
date: 2026-05-04T20:44:57Z
researcher: Paweł Strzałkowski
git_commit: c470885d82d7a004b2ab53708b67a4741c629059
branch: main
repository: pstrzalk/rails-app-generator
topic: "Post-merge chat-agent smoke: LLM is mimicking system-emitted status text and past-tense narration in auto-recap"
tags: [research, chat-agent, prompts, generator-agent, event-subscribers, message-context, smoke-test]
status: complete
last_updated: 2026-05-04
last_updated_by: Paweł Strzałkowski
---

# Research: chat-agent post-merge smoke — LLM mimics system-emitted status text and past-tense narration in auto-recap

**Date**: 2026-05-04T20:44:57Z
**Researcher**: Paweł Strzałkowski
**Git Commit**: c470885d82d7a004b2ab53708b67a4741c629059
**Branch**: main
**Repository**: pstrzalk/rails-app-generator

## Research Question

After the chat-agent-tweak-rebootstrap-and-deferred-handling branch was merged to `main`, the user ran a real-Haiku end-to-end smoke. Trace: `tmp/local_todo_app_with_modifications.log` (15,598 lines, project id 18, chat id 16). Sequence: build a todo list → modify (banner green) → modify (footer green) → during footer build, send two mid-build messages → after auto-recap, confirm and run a combined modification → preview restarts. The architectural fixes from Phases 5–8 worked end-to-end. **What did NOT work cleanly**: three distinct prompt-following issues showed up in the actual chat output, all of them visible to the user in the UI. Document each issue with file:line evidence and concrete log citations. Capture structural / architectural context so a fix plan can be created in a follow-up session. (Per the user's explicit request, also include a tentative prompt-only fix proposal — but mark it clearly as a starting point for the planning session, not a finished design.)

## Summary

The runtime test demonstrated that the design-level fixes from the merged branch are correct in their architecture: 1 `create_application` for the initial build, 3 `modify_application` for tweaks, 0 mutation tool calls during STATE B (in-progress builds), and the auto-recap surfaced both deferred mid-build messages so the user could confirm one combined `modify_application`. All 4 instructions completed; preview ran. (`tmp/local_todo_app_with_modifications.log` end-to-end timeline below.)

What broke at the prompt-following layer:

1. **`🌀 Building…` mimicry** — after every successful mutation tool call, the LLM streams its own assistant message duplicating the system-emitted `🌀 Building: <description>` text. The user sees the building indicator twice in a row.
2. **`✅ Generation finished.` mimicry (BEFORE actual completion)** — in the SAME ChatRespondJob turn that fired `modify_application` and `suggest_prompts`, the LLM produces a second post-tool text iteration containing `✅ Generation finished.` This appears in chat 30+ seconds before the build actually completes; the system then posts its own `✅ Generation finished.` later, resulting in two visually-identical messages with very different timestamps.
3. **"Done!" past-tense narration in the auto-recap turn (no-pending-messages branch)** — when the auto-recap subscriber fires after a build with no mid-build messages, the prompt asks the LLM to "acknowledge that the build finished and ask what they want next." The LLM acknowledges with past-tense claims like *"Done! Your green banner is now at the top of the page."* and skips the question.

The three issues share a root cause beyond just the agent prompt's wording: **system-emitted status messages (`🌀 Building: …`, `✅ Generation finished.`) are persisted with `role: assistant` and have no `system_injected` flag**. RubyLLM/`acts_as_message` then includes them in the LLM's chat-history context on every subsequent turn, where they read as "things the assistant has said before in this position." The LLM imitates the pattern.

## Detailed Findings

### Smoke timeline (project 18, chat 16)

User messages (extracted from `tmp/local_todo_app_with_modifications.log`):

| Time (UTC) | Content | State |
|---|---|---|
| 20:03:48 | "build a todo list" | STATE A, fresh project (uninitialized workspace) |
| 20:03:59 | "no accounts, no xtra features" | clarification |
| 20:04:06 | "go go" | confirmation → fires `create_application` at 20:04:08 |
| 20:12:05 | "add a green banner on top" | post-build #1, STATE A |
| 20:12:19 | "yes" | → fires `modify_application` at 20:12:20 |
| 20:13:48 | "add a green footer as well" | post-build #2, STATE A |
| 20:13:58 | "yes" | → fires `modify_application` at 20:14:00 |
| **20:14:10** | "I also want te background to be red" | **STATE B (build #3 still running)** — LLM correctly stays text-only |
| **20:14:36** | "yes, and make the top banner yellow after all" | **STATE B (build #3 still running)** — LLM correctly stays text-only |
| 20:16:25 | "yes" | post-auto-recap confirmation → fires `modify_application` at 20:16:27 |

Counts:
- 14 ChatRespondJobs completed; 4 ExecuteInstructionJobs completed; 4 instructions in `phase=completed`, 0 failed.
- 1 `create_application` tool call; 3 `modify_application` tool calls; 4 `suggest_prompts` calls.
- 4 `🌀 Building` system messages (one per build) and 4 `✅ Generation finished.` system messages.
- 4 auto-resume nudges (`system_injected: true`, role: user) — one per completed instruction.

Architectural fixes are working as designed.

### Issue 1 — LLM mimics `🌀 Building…` after every mutation tool call

**Evidence (paired system msg + LLM mimic per build):**

| Build | System-emitted msg id (full text) | LLM-streamed msg id (mimicked content) | LLM message has `input_tokens` set? |
|---|---|---|---|
| #1 todo list | 142 (`🌀 Building: Create a simple…`) at log 1713 | 143 — final content `🌀 Building…` at log 1900 | yes (1709 in/88 out) |
| #2 banner green | 154 (`🌀 Building: Add a green banner…`) at log 5970 | 155 — final content `🌀 Building…` at log 6199 | yes (2205 in/87 out) |
| #3 footer green | 166 (`🌀 Building: Add a green footer bar…`) at log 8936 | 167 — full system text (mimicked verbatim) | yes |
| #4 combined | 180 (`🌀 Building: Change the application's main background…`) at log 13323 | 181 — full system text (mimicked verbatim) | yes |

The "input_tokens / output_tokens" UPDATE rows confirm the mimicked messages were streamed by the model (not created by a subscriber). They appear in the chat as a second `🌀 Building` bubble immediately after the system-emitted one.

**Code touched**:
- `app/prompts/generator_agent/instructions.txt.erb:18` — explicitly mentions the literal string `"🌀 Building…"` ("The system itself will display a `🌀 Building…` status").
- `config/initializers/event_subscribers.rb:34-40` — the `instruction.requested` subscriber that persists the system message with `role: :assistant` and no `system_injected` flag, so it later shows up in the LLM's history.
- `app/models/message.rb:8-12` — `visible_in_chat?` returns true for any non-empty assistant message; both the system-emitted and the LLM-mimicked rows render.

### Issue 2 — LLM mimics `✅ Generation finished.` BEFORE the build actually finishes

In the SAME ChatRespondJob that fires `modify_application`, after `suggest_prompts` returns, the LLM produces a *second* post-tool text iteration that streams to `✅ Generation finished.`

**Evidence:**

| Where | Build | Streamed LLM msg id | Final content | Streamed at |
|---|---|---|---|---|
| log 9463–9487 | #3 footer green | 169 | `✅ Generation finished.` | ~20:14:05 (build still running, ~43s before actual completion at 20:14:48) |
| log 13884–13900 | #4 combined | 183 | `✅ Generation finished.` | 20:16:35 (build still running, ~54s before actual completion at 20:17:29) |

After each LLM-mimicked `✅ Generation finished.`, the system later posts its OWN `✅ Generation finished.`:

- Build #3: LLM msg 169 at ~20:14:05; system msg (id 174) at log 11584 timestamped 20:14:48 — 43 seconds apart.
- Build #4: LLM msg 183 at log 13900 timestamped 20:16:35; system msg (id 184) at log 14469 timestamped 20:17:29 — 54 seconds apart.

The user sees two visually-identical `✅ Generation finished.` bubbles separated by tens of seconds, with the first one appearing almost immediately after they confirmed and the second appearing when the actual generation completes.

**Code touched**:
- `app/prompts/generator_agent/instructions.txt.erb:18` — same line that mentions `🌀 Building…`. The "STOP" rule applies after `suggest_prompts` is called, but the LLM's tool loop continues for one more iteration (the post-`suggest_prompts` text slot) and the prompt does not explicitly forbid text in that slot.
- `config/initializers/event_subscribers.rb:54-66` — the `instruction.completed` subscriber that posts the canonical `✅ Generation finished.` later.

### Issue 3 — Auto-recap "Done!" past-tense narration (no-pending-messages branch)

The auto-recap nudge persisted by `instruction.completed` (`config/initializers/event_subscribers.rb:75-109`) hands the LLM two branches:
1. mid-build messages exist → recap and ask to proceed
2. no mid-build messages → "acknowledge that the build finished and ask what they want next"

Branch 2 is producing claim-style, no-question replies:

| Build | LLM msg id | Streamed final content (log line of last update) |
|---|---|---|
| #2 banner green (no mid-build messages) | 160 | `Done! Your green banner is now at the top of the page.` (log 7387) |
| #4 combined (no mid-build messages) | 186 | `Done! Your banner is now yellow and the background is red.` (log 15295) |

For build #3 (footer green) the same pattern likely applied but the user followed up before the auto-recap could play out cleanly — that build had no mid-build messages either, but the user's next message arrived first.

For builds where mid-build messages DID exist (build #4 setup), branch 1 fired correctly:
- Auto-recap msg 176 (build #3 completion): `"So you want two changes: make the main background red, and change the top banner from green to yellow. Should I apply both?"` — recaps both pending messages and ends with a question. Branch 1 works as designed.

So the issue is specifically branch 2: instead of "acknowledge + ask", the LLM emits "Done! [claim]" with no question.

**Code touched**:
- `config/initializers/event_subscribers.rb:90-100` — the `nudge_body` heredoc with the three-step instruction. Line 98 ("acknowledge that the build finished and ask what they want next") doesn't constrain past-tense or completion language and the LLM's response shows it didn't honor "ask what they want next."

### Architectural cross-cutting cause: system-emitted status messages flow back into the LLM's context as if the assistant said them

`config/initializers/event_subscribers.rb` persists status messages with `role: :assistant` and no `system_injected` flag:
- `🌀 Building: <description>` at line 36-39
- `✅ Generation finished.` at line 56-59
- `❌ Revision '<summary>' failed.` / `❌ Generation failed.` at line 117

`app/models/message.rb` (lines 8-12) keeps these visible in the chat UI (the desired behavior — the user should see them), but does not exclude them from RubyLLM's history. `acts_as_message` from RubyLLM picks up the chat's full message history when `Chat#complete` is called, so on every subsequent turn the LLM sees:

- past assistant messages where the body is `"🌀 Building: …"` and `"✅ Generation finished."` ← actually written by `Notifications.subscribe` blocks, but indistinguishable from genuine assistant turns

The `system_injected` boolean column added in Phase 8 (migration `db/migrate/20260504195442_add_system_injected_to_messages.rb`) IS used by `Message#visible_in_chat?` (line 9), `broadcast_append_message` (line 18), and `broadcast_replace_message` (line 27). But it is set ONLY on the auto-recap nudge (event_subscribers.rb:105), not on the `🌀 Building`, `✅ Generation finished.`, or `❌` system status messages. And there is no filter that prevents `system_injected` messages from being sent to the LLM's context — the flag currently exists for UI hiding only.

Combined effect: the LLM's in-context history teaches the model to expect "after every mutation tool call, the assistant body is `🌀 Building…`" and "after every `suggest_prompts` call, the assistant body is `✅ Generation finished.`" — exactly the pattern the user observed.

This is the structural explanation for why a *pure* prompt-text rewrite may not fully eliminate the duplication: even with stricter wording, the few-shot pattern in chat history will keep nudging the model toward mimicry.

### Where Bug A / B / C *did* land cleanly

For sanity, the architectural-level pieces work correctly:

- **Bug A (rebootstrap)** — verified: `app/agents/generator_agent.rb` (current `tools do … end` block in HEAD) gates the bound mutation tool on `Project#workspace_initialized?`. The smoke shows 1 `create_application` (fresh) and 3 `modify_application` (existing app), with zero rebuilds.
- **Bug B (premature "Done!" early in the build)** — partially fixed: the LLM no longer claims completion in the SAME message it would have used for narration in the original bug, but the mimicry of `🌀 Building…` and (worse) the early `✅ Generation finished.` in the post-`suggest_prompts` slot are a re-emergence of the same surface symptom in a different message.
- **Bug C (deferred follow-up)** — verified: build #3's mid-build messages "I also want te background to be red" + "yes, and make the top banner yellow after all" were correctly captured into the auto-recap nudge body, and the LLM's recap response (msg 176) cleanly summarized both and asked for confirmation. The user's next "yes" fired one combined `modify_application` (msg 178). End-to-end this is the textbook result.

## Code References

- `app/prompts/generator_agent/instructions.txt.erb:18` — line that mentions the literal `"🌀 Building…"` string and forbids post-tool narration.
- `app/prompts/generator_agent/instructions.txt.erb:5-14` — STATE A / STATE B branches that worked correctly during the smoke (no tool calls in STATE B).
- `config/initializers/event_subscribers.rb:34-40` — `instruction.requested` subscriber persisting `🌀 Building:` as `role: :assistant`, no `system_injected` flag.
- `config/initializers/event_subscribers.rb:54-66` — `instruction.completed` subscriber persisting `✅ Generation finished.` as `role: :assistant`, no `system_injected` flag.
- `config/initializers/event_subscribers.rb:75-109` — auto-recap subscriber (Bug C fix); the `nudge_body` heredoc lines 90-100 contain the three-step instructions, including line 98 (the no-pending-messages branch).
- `config/initializers/event_subscribers.rb:111-124` — `instruction.failed` subscriber, structurally identical for `❌` messages.
- `app/models/message.rb:8-12` — `visible_in_chat?` filters out `system_injected` from UI but lets non-flagged assistant messages render.
- `app/models/message.rb:16-23` — `broadcast_append_message` skips `system_injected` (UI-only filter).
- `app/models/message.rb:26-33` — `broadcast_replace_message` skips `system_injected` (UI-only filter).
- `db/migrate/20260504195442_add_system_injected_to_messages.rb` — adds the column with `default: false, null: false`.
- `tmp/local_todo_app_with_modifications.log:1713` — system msg 142 `🌀 Building: Create a simple…`
- `tmp/local_todo_app_with_modifications.log:1900` — LLM msg 143 final content `🌀 Building…`, with `input_tokens=1709` proving model authorship
- `tmp/local_todo_app_with_modifications.log:5970` — system msg 154
- `tmp/local_todo_app_with_modifications.log:6199` — LLM msg 155 (mimic)
- `tmp/local_todo_app_with_modifications.log:8936` — system msg 166
- `tmp/local_todo_app_with_modifications.log:9463-9487` — LLM msg 169 streamed to `✅ Generation finished.` ~43s before actual completion of build #3
- `tmp/local_todo_app_with_modifications.log:11584` — actual `✅ Generation finished.` system msg for build #3
- `tmp/local_todo_app_with_modifications.log:13323` — system msg 180
- `tmp/local_todo_app_with_modifications.log:13884-13900` — LLM msg 183 streamed to `✅ Generation finished.` ~54s before actual completion of build #4
- `tmp/local_todo_app_with_modifications.log:14469` — actual `✅ Generation finished.` system msg for build #4
- `tmp/local_todo_app_with_modifications.log:7351-7399` — LLM msg 160 streaming `Done! Your green banner is now at the top of the page.` (auto-recap, build #2)
- `tmp/local_todo_app_with_modifications.log:15223-15295` — LLM msg 186 streaming `Done! Your banner is now yellow and the background is red.` (auto-recap, build #4)

## Architecture Documentation

### Two parallel persistence paths into the same Chat

1. **LLM-driven path**: `ChatRespondJob` calls `agent.complete`, RubyLLM creates `Message(role: assistant)` rows and streams content into them, then persists `ToolCall` rows for any tool calls. Each row gets `input_tokens`, `output_tokens`, `model_id` populated when streaming finalizes.

2. **Subscriber-driven path**: `ActiveSupport::Notifications` subscribers in `config/initializers/event_subscribers.rb` create `Message(role: assistant)` rows directly (no LLM call), with hand-written `content` strings: `🌀 Building: …`, `✅ Generation finished.`, `❌ …`.

Both paths write to the same `chat.messages` association. The `system_injected` boolean column distinguishes one specific subset (auto-resume nudges, which use `role: user` and live at `event_subscribers.rb:102-106`), but the system status messages do NOT use `system_injected` — they pass through the same channel as genuine LLM responses.

### Read paths

- **UI (browser)**: messages render via `messages/_message.html.erb` partial; `Message#visible_in_chat?` filters out `system_injected` rows. System status messages render normally.
- **LLM context**: `RubyLLM::Agent#complete` → `Chat#with_runtime_instructions / with_tools / complete` builds the message list from the chat's `messages` association. The subscriber-emitted assistant messages are sent to the LLM as if they were prior assistant turns.

### Tool loop iteration

When `Chat#complete` runs, RubyLLM iterates: model emits text + optional tool_calls → tool executes → result is added to context → model gets called again. The agent prompt's "STOP after `suggest_prompts`" applies to one specific slot, but the model produces a final post-tool text iteration after every successful tool result by default. Issue 2 (the early `✅ Generation finished.`) lives in this final iteration.

## Tentative prompt-only fix proposal (starting point for the future planning session, not a recommendation)

Per the user's explicit request, sketches:

**Sketch A — `app/prompts/generator_agent/instructions.txt.erb`**: rewrite line 18 to (a) avoid mentioning the literal `🌀 Building…` string, (b) constrain ALL post-tool text slots, not just the one between mutation tool and `suggest_prompts`, (c) explicitly forbid mimicking system completion language.

> *Candidate text: "After `create_application`/`modify_application` returns: leave your text response EMPTY. Then call `suggest_prompts` with 3-5 next steps. After `suggest_prompts` returns, leave the next text response EMPTY too and stop. Never type build-started or completion-finished status text — those belong to the system, not you."*

**Sketch B — `config/initializers/event_subscribers.rb:90-100`** (the auto-recap nudge body, no-pending-messages branch): replace "acknowledge that the build finished and ask what they want next" with a stricter rule that forbids past-tense claim language and requires a question.

> *Candidate text: "If they sent no change requests (or only questions), greet them in ONE short sentence (NO past-tense claims, NO 'Done!', NO 'Updated', NO 'Finished' — the system has already shown the completion indicator) and end with a question asking what they want to change next."*

### Why prompt-only may not be sufficient on its own

Because system-emitted `🌀 Building: …` and `✅ Generation finished.` rows are stored as `role: :assistant` and are NOT excluded from RubyLLM's history when `Chat#complete` runs again, every subsequent turn shows the model an in-context pattern of "after `modify_application`+`suggest_prompts`, the assistant body is `🌀 Building: …`/`✅ Generation finished.`" The few-shot pull of these prior messages will keep nudging the model toward mimicry even if the prompt forbids it. The planning session should consider:

- **Structural Sketch C — extend `system_injected` to also filter from LLM context**, then mark `🌀 Building`, `✅ Generation finished.`, `❌ …` rows as `system_injected: true`. This would require either (a) a custom override of RubyLLM's message-list construction to skip `system_injected` rows, or (b) using `role: :tool` / `role: :system` for these rows so they're never serialized as assistant context. (a) keeps the UI render path unchanged; (b) requires updating UI rendering paths that filter on role.
- **Sketch D — store status messages in a separate table** (e.g. `chat_events`) with their own broadcast partial, decoupling them entirely from the Message model's LLM-context contract. Larger refactor.

These are sketches only — the planning session should research the RubyLLM message-construction internals, the UI rendering paths that consume `chat.messages`, and the cost of each option.

## Historical Context (from thoughts/)

- `./thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md` — original research that motivated the merged branch; documented Bug A / B / C with concrete log evidence from the 2026-05-04 storybook smoke. The "Bug B — Premature 'Done!' reply" section is the precursor to today's findings: the same surface symptom appears in a different message slot, suggesting the underlying tendency wasn't fully suppressed.
- `./thoughts/shared/plans/2026-05-04/chat-agent-tweak-rebootstrap-and-deferred-handling.md` — the implementation plan that landed the current architecture. Phase 7 (Bug B fix) and Phase 6 (confirmation-first prompt) are the directly relevant sections; the explicit "do NOT write any text" wording at line 973 of the plan is the source of the agent prompt's current "After `create_application`/`modify_application` returns, do NOT write any text." line.
- `./thoughts/shared/plans/2026-05-04/chat-agent-tweak-fix/00-overview.md` — index document for the same 9-phase plan.

Memory entries that may inform the planning session:
- `project_ruby_llm_partial_path` — RubyLLM message lifecycle, `to_partial_path` overrides per role.
- `project_ruby_llm_message_lifecycle` — tool_calls attach AFTER `message.save!`; `on_new_message` block is 0-arg.
- `project_ruby_llm_chat_api` — `Chat#complete` takes only a block; tools/schema/choice come from `with_tool` / `with_tools` / `with_schema`.
- `feedback_no_logic_in_views` — extract view branching to helpers OR model. Relevant if Sketch D introduces a separate "chat events" rendering path.

## Related Research

- `./thoughts/shared/research/2026-05-04/chat-agent-design-tweak-rebootstrap-and-deferred-handling.md` — direct precursor; same project, same chat agent, three-bug analysis that led to the merged plan.

## Open Questions

These are explicitly left for the future planning session:

1. **Does `RubyLLM::Agent#complete` (via `acts_as_message`) provide a hook to filter messages before serialization to the LLM?** If yes, marking system-status rows as `system_injected: true` and adding a single filter call may be the smallest fix. If no, what's the cost of either an override or a role-based separation?
2. **What other consumers read `chat.messages` and assume role-based filtering?** UI rendering, `bin/inspect-chat <project_id>`, the ToolCall touch hook (memory `project_ruby_llm_message_lifecycle`), the auto-recap subscriber's `pending` query (already filters `system_injected: false` at `event_subscribers.rb:80`).
3. **Is there a way to verify a fix without a real-Haiku run?** The unit and integration tests in the merged branch exercise tool-surface gating and subscriber behavior, but they don't catch in-context few-shot mimicry. Could a stubbed-LLM integration test prove the LLM's history is filtered correctly?
4. **Should `❌ Generation failed.` messages also be hidden from LLM context?** They probably should — the same mimicry risk applies if a future prompt ever discusses failure handling.
5. **Wall-time cost of this exact smoke**: 4 builds in ~13 minutes (20:03:48 → 20:17:29). Is this representative or biased by Haiku's first-build cache miss? Worth noting because the test budget in `test/integration/generate_todo_list_test.rb:21` is 900s for ONE build.
