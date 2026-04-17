# Layer integration

How RubyLLM, Roast, and Solid Queue communicate with each other.

## Principle

Layers don't import each other. Communication happens through events at the boundaries. Phase 1 uses `ActiveSupport::Notifications` as a lightweight event bus. Phase 2 can swap in any pub/sub without changing workflows or chat.

## Diagram

```
RubyLLM (chat)                    Roast (workflows)
     │                                  │
     │  tool call                       │  workflow step
     ▼                                  ▼
┌──────────┐                     ┌──────────────┐
│ Publish:  │                     │ Publish:      │
│ instruction│                    │ revision      │
│ .requested│                     │ .completed    │
└─────┬─────┘                     └──────┬───────┘
      │                                  │
      ▼                                  ▼
┌─────────────────────────────────────────────────┐
│  ActiveSupport::Notifications (event bus)        │
│  Phase 1: in-process, synchronous subscribers    │
│  Phase 2: swappable for pub/sub, message queue   │
└─────────────────────────────────────────────────┘
      │                                  │
      ▼                                  ▼
┌──────────┐                     ┌──────────────┐
│ Subscribe:│                     │ Subscribe:    │
│ enqueue   │                     │ enqueue       │
│ Roast job │                     │ follow-up job │
└──────────┘                     └──────────────┘
```

## Events — phase 1

```ruby
# Emitted by the conversation layer (RubyLLM tool handlers)
"instruction.requested"    # user wants to generate  → payload: { instruction_id: }
"instruction.cancelled"    # user wants to cancel    → payload: { instruction_id: }
"undo.requested"           # user wants to undo      → payload: { project_id: }

# Emitted by the execution layer (Roast workflows)
"revision.started"         # revision started        → payload: { revision_id: }
"revision.completed"       # revision completed      → payload: { revision_id:, git_sha: }
"revision.failed"          # revision failed         → payload: { revision_id:, error: }
"instruction.completed"    # full instruction done   → payload: { instruction_id: }
"instruction.failed"       # instruction failed      → payload: { instruction_id: }
"preview.ready"            # preview started         → payload: { project_id:, url: }
```

## Problem 1: Roast → chat feedback loop

Roast doesn't know about the chat. It publishes an event. A subscriber enqueues a job.

```ruby
# Roast workflow — last step
ruby(:publish_completed) do
  ActiveSupport::Notifications.instrument("instruction.completed", instruction_id: instruction.id)
end

# Subscriber (config/initializers/event_subscribers.rb)
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  ChatFollowUpJob.perform_later(payload[:instruction_id])
end

# Job — the only place where the layers "touch"
class ChatFollowUpJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    # RubyLLM generates follow-up in the chat
    project.chat.ask("Generation completed. Suggest next steps.", tools: [SuggestPrompts])
  end
end
```

Same for failure:
```ruby
ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
  ChatFollowUpJob.perform_later(payload[:instruction_id], event: :failed)
end
```

**Coupling: zero.** Roast emits an event. Subscriber is glue code. RubyLLM runs in a job. No layer imports another.

**Phase 2**: instead of enqueueing a job, the subscriber publishes to a message queue. Job on the other side. Zero changes in Roast and RubyLLM.

## Problem 2: Cancel mid-workflow

Cancel is a DB flag + an event. The workflow checks the flag between steps.

```ruby
# RubyLLM tool handler
class CancelInstruction < RubyLLM::Tool
  def execute
    instruction = current_instruction
    instruction.update!(phase: :cancelled)
    ActiveSupport::Notifications.instrument("instruction.cancelled", instruction_id: instruction.id)
  end
end

# Subscriber
ActiveSupport::Notifications.subscribe("instruction.cancelled") do |*, payload|
  CancelWorkflowJob.perform_later(payload[:instruction_id])
end

# CancelWorkflowJob — kills the Claude CLI process if running
class CancelWorkflowJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    # Kill running CLI process if PID is saved
    Process.kill("TERM", instruction.cli_pid) if instruction.cli_pid
    # Git reset to the last completed revision
    GitService.reset_to_last_completed(instruction.project)
  end
end
```

Inside a Roast workflow — check between steps:
```ruby
# Helper invoked between steps
ruby(:check_cancelled) do
  raise Cancelled if instruction.reload.cancelled?
end
```

**Phase 1**: DB flag + SIGTERM on PID. Simple, works.
**Phase 2**: "instruction.cancelled" event may be broadcast to the workflow runner in real time (e.g., via Action Cable internally), without polling the DB.

## Problem 3: Two LLM clients

Phase 1: we accept it. Clear division:

| Client | Layer | Calls |
|--------|-------|-------|
| RubyLLM | Conversation | Chat with the user, tool calls, suggested prompts |
| Raix (Roast) | Workflow | Research, planning, update docs (`chat()` steps in Roast) |
| Claude CLI | Workflow | Code generation (`agent()` step in Roast) |

Shared configuration:
```ruby
# config/initializers/llm.rb
# Both read from the same ENV vars
RubyLLM.configure { |c| c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
# Raix/Roast is configured separately but from the same source
```

Cost tracking — one service, many sources:
```ruby
class CostTracker
  def self.record(source:, tokens:, model:, instruction_id:)
    # source: "rubyllm", "roast", "claude_cli"
    CostEntry.create!(source:, tokens:, model:, instruction_id:)
  end
end
```

**Phase 2**: if we want to unify — RubyLLM as the only client. Roast `chat()` steps replaced with custom `ruby()` steps calling RubyLLM. But that's optimization, not necessity.

## Turbo Streams — broadcasting from workflows

Roast workflow emits events. A subscriber broadcasts to the UI.

```ruby
ActiveSupport::Notifications.subscribe("revision.started") do |*, payload|
  revision = Revision.find(payload[:revision_id])
  revision.broadcast_replace_to(revision.project, target: "revision_#{revision.id}")
end

ActiveSupport::Notifications.subscribe("revision.completed") do |*, payload|
  revision = Revision.find(payload[:revision_id])
  revision.broadcast_replace_to(revision.project, target: "revision_#{revision.id}")
end
```

The Roast workflow doesn't know about Turbo Streams. It publishes an event, someone else broadcasts.

## Guidelines

### Subscribers: only enqueue or broadcast

An `ActiveSupport::Notifications` subscriber **never** runs heavy logic. It does one of two things:
- `SomeJob.perform_later(...)` — schedules work to Solid Queue
- `broadcast_replace_to(...)` — broadcasts a Turbo Stream

Everything else goes into a job.

### HTTP request: only save + enqueue

An HTTP request never waits on the LLM, Roast, or Claude CLI. Request lifecycle:
1. Save data (Message, Instruction)
2. Enqueue job
3. Return

All work happens in Solid Queue workers. Events are emitted from workers, not from requests.

### ActiveSupport::Notifications — synchronous, by design

Notifications run synchronously in the process that emits them. This is not a problem because:
- We emit from Solid Queue workers, not from HTTP requests
- Subscribers do only enqueue/broadcast (milliseconds)
- Heavy work goes into separate jobs

In phase 2 this event bus can be replaced with async pub/sub (e.g. Solid Queue pub/sub, a dedicated broker). The event interface (names, payloads) stays the same — only the transport changes.

## Flow-break ready

Thanks to events at the boundaries, in phase 2 we can insert a flow-break at any stage:

```
revision.completed → subscriber checks: is a manual checkpoint needed?
  [yes] → don't enqueue the next revision, wait for an event from the user
  [no] → continue normally
```

This is the seed of a pub/sub architecture without building pub/sub.
