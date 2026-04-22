# Deferred user request after generation completes — ideas

When a user sends a new build request mid-generation (e.g. "Mark todos as
complete", "Add user authentication"), the LLM currently — thanks to the
runtime state line injected into the system prompt + Phase 5's tool guard —
declines to call `start_generation` and tells the user the build is finishing
and they'll handle the change afterward.

Observed 2026-04-22 during Phase 2 Step 6 manual verification.

## The question

Once `✅ Generation finished.` fires, what happens with the deferred request?

Today: nothing. The LLM has told the user "I'll apply this as soon as it's
done", but there is no mechanism that resumes the pending request
automatically. The user has to re-send the message, which is:

- user-hostile ("I already told you")
- wasteful on tokens (we re-burn the chat history for a re-send)
- inconsistent with the implicit promise in the LLM's reply

## Options to consider

### A. LLM-side — system kicks the LLM after generation completes

When `instruction.completed` fires, enqueue a job that nudges the LLM
(e.g. via `chat.ask("The generation finished. Re-read the most recent
user turn; if a change was requested and not yet started, call
start_generation for it now.")`). The runtime state line will have
flipped to "No generation is currently running" by then, so Phase 5's
guard won't refuse.

Risks: the LLM might start *old* deferred requests from earlier turns the
user no longer cares about. Needs a bounded scope — "the most recent
user turn after the last start_generation", not "anything unresolved".

### B. UI-side — explicit pending-request affordance

When the LLM declines mid-run, it also returns a structured "deferred
request" marker. The UI shows a pill/card: "📌 Pending after build:
Mark todos as complete" with a "start now" button that becomes active
after `✅ Generation finished.`.

Pro: user is in control, no surprise tool calls.
Con: more UI + a new data type to model.

### C. Reject the mid-run prompt outright

Controller-level: if an active instruction exists, reject a new user
message with "wait until the current build finishes." Cleanest behavior,
worst UX — users can't even queue their thoughts.

### D. Hybrid — LLM summarises, UI owns the queue

Mid-run, the LLM converts the user request to a summary ("add a 'mark
complete' button on todos") and emits a `QueueRequest` tool call. The
summary becomes a card in the UI. After completion, the user clicks
"run queued requests" → a single `start_generation` call with the
summary as intent. No surprise, explicit control.

## Dependencies

- Likely requires the refused-tool-call pill UX fix we skipped in Step 6.
  If the "Starting generation..." pill flashes before the refusal, any
  queue card is competing for attention with a stale activity indicator.
- Interacts with the "what does `SuggestPrompts` show after completion"
  decision. Today Phase 4 is deliberately minimal — just the status
  line. A queue would sit naturally next to whatever the completion UI
  becomes.

## When to pick this up

Not Phase 2. Step 7 closes the PoC without this — user re-sending is
acceptable for the demo. Revisit when:

- the UI gets its next round of work (demo polish, or as part of Phase 3
  preview wiring), or
- a second user reports the same "I already told you" friction in manual
  testing.
