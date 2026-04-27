# Happy Path — User Story (v4)

Full user path from opening the page to a working application.

## Architectural principles

- **Chat is the only interface** — no separate fields, forms, project statuses. Everything happens in conversation.
- **Everything is versioned** — version A + instruction X = version B. Every change is a git commit.
- **RubyLLM as the foundation** — conversation layer built on RubyLLM, with tools as the control mechanism.
- **Chat = intent concierge** — the chat LLM gathers intents from the user and passes them to the generation layer via a tool call. It does not generate an implementation plan, does not know the full structure of the generated app, does not see detailed prompts. Plan prompt engineering lives in the `CreatePlan` service; implementation details live in the workspace (git repo). Chat sees only user-facing revision summaries (git commit messages).
- **Tool calls drive the process** — the LLM decides about generating, cancelling, suggesting next steps via tool calls. UI buttons are a safety net, not the primary flow.
- **Suggested prompts guide the user** — the system proposes next steps as editable prompts. The user doesn't have to know what to say.
- **Two independent timelines** — chat runs continuously, revisions are created at specific points. Synchronized via anchor.
- **Linear history** — always forward. Undo = git revert. Architecture supports future rewind, but we don't implement it.
- **Research → Plan → Implement → Verify** — every Instruction goes through these phases. We don't jump to code without understanding context. We don't commit code that doesn't pass verification. Modeled on the [Visuality AI coding workflow](https://www.visuality.pl/posts/from-vibes-to-process-ai-coding-in-production-codebases).

---

## RubyLLM Tools — the control mechanism

The LLM has access to tools. This is the only way to trigger actions in the system. UI buttons are aliases to the same thing.

### Tools

```ruby
# Starts generation. Passes INTENT, not a plan.
class StartGeneration < RubyLLM::Tool
  param :intent, type: :string, desc: "Plain language: what the user wants to build"
  param :clarifications, type: :object, desc: "Answers to clarifying questions (key/value)"
  # LLM calls this when the user is ready. Does NOT invent a plan — the tool handler delegates
  # to the CreatePlan service, which generates revisions (detailed prompts) inside its own system
  # prompt. The chat LLM never sees the generated plan — it only gets a confirmation
  # (instruction_id, revision_count).
end

# Cancels the current instruction.
class CancelInstruction < RubyLLM::Tool
  # LLM calls this when the user writes "stop" / "change approach"
end

# Proposes next steps to the user. UI renders as clickable/editable cards.
class SuggestPrompts < RubyLLM::Tool
  param :prompts, type: :array, desc: "List of suggested prompts with optional blanks to fill in"
  # LLM calls this after generation completes, after answering a question, or when the user is unsure
end

# Reverts the last change (git revert as a new revision).
class UndoLastChange < RubyLLM::Tool
  # LLM calls this when the user writes "undo"
end
```

### The `CreatePlan` layer — a separate service, not a tool

The `StartGeneration` tool is lightweight — it only passes intent to the `CreatePlan` service. The service lives outside the chat, has its own system prompt (rules like "Rails Way, 3-6 steps, Tailwind, Hotwire, Devise..." — the project's secret sauce), and generates a list of revisions with detailed prompts for Claude CLI.

```ruby
module CreatePlan
  # Interface: returns an array of { summary:, prompt: } ready for Revision.create!
  def self.call(intent:, clarifications: {}, context: {})
    implementation.call(intent: intent, clarifications: clarifications, context: context)
  end

  def self.implementation
    @implementation ||= AdHocLLM  # Future: Archetypes, Hybrid, CheapButGood
  end

  class AdHocLLM
    # LLM call with a dedicated system prompt (secret sauce).
    # NOT visible to the chat LLM or to the user.
  end
end
```

Why separate: plan quality = key to generator quality. Swappable implementations (archetype, hybrid, cheap-but-good model) are a separate workstream. The planner's system prompt is 100% under our control, not mixed with the chat system prompt. Decisions D1/D3 from `../02-architecture/01-workflows-and-decisions.md` live here.

### Context for the LLM

On every `chat.ask(...)` the LLM gets in context:
- Conversation history (RubyLLM does this automatically)
- **Status of the current instruction** (if one is active): which revision is being generated, how many are done, how many remain
- **List of project revisions** — **only `summary` + `status`**, i.e. the user-facing view of what's happening (summaries are git commit messages, understandable to the user)
- Available tools

What the LLM **does not** get (a direct consequence of the "chat = intent concierge" principle):
- Detailed revision prompts (`Revision.prompt`) — these go only to Claude CLI via the Roast workflow
- File tree of the generated app, model schema, controller contents
- Claude CLI outputs, verification logs, stack traces (failure payload is summarized into a user-facing description before entering context)
- The `CreatePlan` system prompt or the generated plan before revisions start

Thanks to this, the LLM can react to what the user sees: "I see step 3 failed, I'll try a different approach" or "generation is done, here are some next steps." But it doesn't start a conversation about controller architecture and doesn't write "I added method X in class Y" — because it doesn't know that.

### Flow

```
User message
    ↓
RubyLLM chat.ask(message, tools: [...], context: generation_status)
    ↓
LLM responds with text + optionally tool calls
    ↓
    ├── text → Message in chat → Turbo Stream
    ├── StartGeneration → CreatePlan service → Instruction + Revisions → orchestration
    ├── CancelInstruction → cancels current → git reset
    ├── SuggestPrompts → renders cards in UI → user clicks/edits
    └── UndoLastChange → git revert as a new revision
```

---

## Suggested Prompts — guiding the user

The user doesn't have to know what to say. The system suggests.

### What they look like

After generation completes:
> *App ready! What next?*
> - [Add authentication — customers log in with email and password]
> - [Add an admin panel for managing ___]
> - [Change color scheme to ___]

Each suggestion is a clickable card with text. The text may have blanks (`___`) for the user to fill in. Click → text lands in the input → user can edit → sends.

### When they appear

The LLM calls `SuggestPrompts` at natural moments:
- After the first message (guided): direction suggestions (e.g. *"booking system with calendar"*, *"digital product store"*)
- **After generation completes**: what to add next
- After answering a question: "Would you also like to..."
- When the user writes something unclear: clarifying suggestions

Suggestions **do not include** plan approval before start — the user doesn't see the plan. After collecting intent the LLM simply calls `StartGeneration`, generation starts, the user sees progress.

### They are not mandatory

The user can always ignore suggestions and write anything. Suggestions are help, not a constraint.

---

## Research → Plan → Implement → Verify

Every Instruction goes through these phases. Modeled on the [Visuality AI coding workflow](https://www.visuality.pl/posts/from-vibes-to-process-ai-coding-in-production-codebases). Verify is what sets us apart from vibe coding — we don't commit code that doesn't pass verification.

Key principle: **the center of gravity of research shifts toward pre-existing knowledge**, but we don't eliminate exploration. The archetype and app manifest are the starting point — they let us enter context quickly. Deeper research happens when needed (new domain, new solutions, non-obvious problem).

### Two sources of pre-existing knowledge

**1. Archetype database (new apps)**

Internal knowledge base about application types. Our core IP.

- "E-commerce with delivery" → pattern: Product, Cart, Order, Delivery, Payment. Devise for customers, Avo admin, Stripe.
- "Booking system" → pattern: Resource, Slot, Booking, Calendar. Availability logic, reminders.
- "SaaS with subscriptions" → pattern: Account, Plan, Subscription, Billing. Multi-user, Pay gem.
- "Blog/CMS" → pattern: Post, Category, Tag, Author. Action Text, SEO.

An archetype is not a template — it's a bundle of domain knowledge + technical recommendations. A starting point, not a ready-made answer. An app like "flower shop with same-day delivery" may fit the e-commerce archetype, but "same day" requires additional research (logistics, time slots, geographic constraints).

The database grows over time — every new app teaches us new patterns.

**2. App manifest (existing apps)**

Every generated app maintains documentation about itself. Updated after every revision.

```
docs/
  architecture.md    — models, relations, key controllers, routing
  conventions.md     — decisions made, gems used, patterns
  domain.md          — domain glossary, business rules
```

The manifest lets us enter context quickly without scanning the codebase. But it doesn't eliminate the need for research — "add a discount system" requires investigating how discounts should interact with the existing order model, which gems may help, what edge cases need to be solved.

After every revision: the **"update docs" step** updates the manifest. Part of the implementation process.

### Cycle per Instruction

Instructions executed by defined workflows (see `../02-architecture/01-workflows-and-decisions.md`).

**New app → Workflow W1:**

| Step | Type | What happens |
|------|------|--------------|
| W1.1 | deterministic | Load archetype |
| W1.2 | LLM (decision D1) | Domain research — if the archetype doesn't cover the requirements |
| W1.3 | LLM | Generate plan |
| W1.4 | deterministic | Create Revision records |
| W1.5 | loop → W2 | Execute revisions |
| W1.6-7 | deterministic | Close instruction, start preview |

**Iteration → Workflow W4:**

| Step | Type | What happens |
|------|------|--------------|
| W4.1 | deterministic | Load app manifest |
| W4.2 | LLM (decision D3) | Research — manifest is enough / look for new solutions / read code |
| W4.3 | LLM | Generate plan |
| W4.4 | loop → W2 | Execute revisions |
| W4.5-6 | deterministic | Close instruction, restart preview |

Non-deterministic decisions (D1, D3) are explicitly described points in workflows — not "the agent judges for itself" but "step W4.2 with options [a] manifest is enough [b] look for solutions [c] read code."

### Verification + remediation (safeguard)

After every revision (W2.4) verification runs: bundle check, migrations, herb lint, boot check, tests. If something doesn't pass:

1. **Remediation loop** (max 2 attempts): errors go back to Claude CLI → agent fixes → re-verify
2. If still failing after 2 attempts → W2.F1: mark the revision as failed with full error log
3. W2.F2: git reset to parent revision
4. W2.F3: report to the conversation layer → agent (decision D6) reacts in chat, has context about what exactly failed

Key: **we don't commit code that doesn't boot.** Git history contains only working revisions.

### Manual checkpoints (safeguard, guided mode)

Between larger revisions the agent can pause and ask for review:
> *Models are ready. Before I move to views — do you want to review the structure?*

In quick mode — no checkpoints, full automation.

---

## Data model

```ruby
Project
  - name: string
  - workspace_path: string
  has_one :chat
  has_many :instructions
  has_many :revisions

Chat (RubyLLM)
  belongs_to :project
  has_many :messages

Message (RubyLLM)
  belongs_to :chat
  - role: enum (user, assistant, tool)
  - content: text
  # tool call messages contain tool invocations and their results

Instruction
  belongs_to :project
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions
  - phase: enum (researching, planning, implementing, completed, failed, cancelled)
  - description: text
  - research_output: text   # output of the research phase (context for plan and implementation)

Revision
  belongs_to :project
  belongs_to :instruction
  belongs_to :parent, class_name: "Revision", optional: true
  - git_sha: string
  - summary: text
  - position: integer
  - status: enum (pending, generating, completed, failed)
```

### Key decisions

**Instruction is created from a tool call** — not from application logic. The LLM calls `StartGeneration(intent, clarifications)`, the tool handler delegates to the `CreatePlan` service which generates revisions, then creates an `Instruction` record + N × `Revision`. Anchor = the message with the tool call.

**Cancel from a tool call** — the LLM interprets "stop" and calls `CancelInstruction`. The "Cancel" button in the UI does the same (creates a system message + invokes the same handler).

**SuggestPrompts is a tool call, not a separate model** — suggestions are rendered from the tool result message. They don't need their own table.

**UI buttons = aliases** — the "Cancel" button in the UI creates a message (role: user, content: "[cancel requested]") and invokes the `CancelInstruction` handler. Effect is identical to the user writing "stop" and the LLM calling the tool.

### Two timelines

```
Chat:       msg1 → msg2 → msg3(tool:start) → msg4 → msg5 → msg6(tool:suggest) → msg7 → msg8(tool:start)
                              |                                                              |
                            anchor                                                         anchor
                              |                                                              |
Instruction:               instr1                                                         instr2
                              |                                                              |
Revisions:     rev1 → rev2 → rev3                                                         rev4

- msg3 is a StartGeneration tool call — anchor at this point. CreatePlan service creates rev1-rev3.
- msg4-msg5 is conversation DURING generation
- msg6 is a SuggestPrompts tool call after completion — user sees suggestions
- msg7 is the user clicking a suggestion (or writing their own)
- msg8 is a StartGeneration tool call with a new instruction — CreatePlan creates rev4
```

---

## Step 1: New project

### What the user sees
Text field. Example prompts for inspiration. Two buttons: "Quick" / "Guided".

### What the user does
Types: *"An app for selling and delivering flowers..."*

### Server (synchronously)
1. `Project.create!`, `Chat.create!`, `Message.create!(role: :user)`
2. `git init` in workspace
3. Redirect → `/projects/{id}`
4. `ChatRespondJob.perform_later` — LLM processes the first message

---

## Step 2: Conversation (guided path)

### What the user sees
Chat. The system responds with questions + suggestions:

> *A few questions:*
> 1. *Separate admin panel or shared interface?*
> 2. *Delivery tracking or simple status?*
>
> [Separate admin panel, full delivery tracking]
> [Shared interface, simple order status]
> [___]

Suggestions are ready answers — click and send. Or the user writes their own.

### Server
1. `Message.create!(role: :user)`
2. `ChatRespondJob`:
   - `chat.ask(...)` with tools + generation context
   - LLM responds with text + `SuggestPrompts` tool call
   - Text → Message → Turbo Stream
   - Suggestions → rendered as cards under the message

### Quick path
The LLM immediately calls `StartGeneration(intent, clarifications: {})` without clarifying questions.

---

## Step 3: Start generation

There is no "show plan, user approves". After collecting intent the LLM calls `StartGeneration` and generation begins. The user sees progress, not the plan.

### What the user sees
A short message from the LLM + a list of ongoing revisions appearing next to/under the chat:

> *OK, got it. I'm starting to build — you'll see progress below.*
>
> ⏳ Revision 1: "Rails scaffolding + Tailwind" — *generating*
> ⚪ Revision 2: "Domain models (Product, Order, Delivery)" — *pending*
> ⚪ Revision 3: "Customer panel" — *pending*
> ⚪ Revision 4: "Florist panel" — *pending*
> ⚪ Revision 5: "Devise auth + roles" — *pending*

The user sees **only revision summaries** (user-facing, git commit-like). Detailed prompts (`Revision.prompt`) live in DB and go to Claude CLI, but **never reach the UI or the chat**.

### Server
1. LLM calls `StartGeneration(intent: "flower shop with same-day delivery", clarifications: {admin_panel: "separate", delivery_tracking: "full"})`
2. Tool handler:
   - `CreatePlan.call(intent, clarifications)` — service generates revisions with its own system prompt (secret sauce)
   - `Instruction.create!(anchor_message: msg, phase: :processing)`
   - `Revision.create!` per generated revision, status: `pending`
3. The tool returns to the LLM **only a confirmation**: `{instruction_id, revision_count: 5, intent}`. The LLM does not receive `Revision.prompt` contents.
4. Event `instruction.requested` → Solid Queue triggers workflow W1 (from step W1.5 — loop over revisions)

### Where the "plan" lives
- **Intent + clarifications** — in the tool call arguments, visible in chat
- **Revision summaries** — user-facing, in DB (`Revision.summary`), in the UI, in chat context after they are created
- **Detailed prompts** — in DB (`Revision.prompt`), read by the Roast workflow, nowhere else

---

## Step 4: Generation

### What the user sees
Chat open. Progress in chat or a side panel:

> ⏳ *Generating (step 2/6: Domain models)...*

The user can write, ask, comment. They can write *"stop"* → the LLM calls `CancelInstruction`.

### Server — orchestration

**`GenerationOrchestrator`** — sequentially processes `pending` revisions.

**`ExecuteRevisionJob`**:
1. `revision.update!(status: :generating)` → Turbo Stream
2. Prompt + context (plan + app manifest + revision notes from the previous revision) → `claude -p "..." --cwd workspace/...`
3. Stream output → Turbo Stream (throttled)
4. **Verify**: `bundle check` → `rails db:prepare` → `herb lint` → `rails runner "puts :ok"` → `rails test`
5. If verify fails → **remediation loop** (errors → Claude CLI → re-verify, max 2 attempts)
6. `git commit` → update app manifest + revision notes → `revision.update!(status: :completed, git_sha: sha)`
7. Next revision

**After all revisions complete:**
- `instruction.update!(status: :completed)`
- Generation status goes into the LLM context
- LLM reacts automatically: `SuggestPrompts` with proposals for what's next
- Preview starts (step 5)

**Failure:**
- `revision.update!(status: :failed)`, stop
- Status goes into LLM context → LLM reacts in chat (proposes retry / change of approach)

**Cancel:**
- `CancelInstruction` tool → `instruction.cancelled!`
- `git reset --hard` to the last completed revision
- LLM reacts: *"Stopped. What next?"* + `SuggestPrompts`

### Git as checkpointing
- `git commit` after every revision
- Rollback = `git reset --hard {parent.git_sha}`

### CLI
```bash
bin/generate execute --project-id=123 --revision-id=456
```

---

## Step 5: Preview

### What the user sees
Split view: chat + iframe with the working application.
Below the chat: suggestions for what's next.

### Server
`StartPreviewJob` (button-driven in Phase 3, not auto):
1. `docker build -f lib/preview/Dockerfile <workspace>` against a pre-baked `preview-base:latest` image
2. `docker run -d` with hardened flags: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--read-only` + tmpfs for `/tmp` `/app/tmp` `/app/log`, `--memory=512m`, `--cpus=0.5`, `--pids-limit=100`, `--network=preview-internal`
3. Health-check via `curl /up`; once green, render the iframe
4. **Phase 3 PoC**: iframe `src` is `http://localhost:#{3000 + project.id}`. **Phase 4**: `https://#{id}.preview.<domain>` via kamal-proxy + wildcard cert

The iframe is `sandbox="allow-same-origin allow-scripts allow-forms"`.

### Potential problems
- **Isolation** — ✅ solved in Phase 3 (hardened Docker container per preview)
- **Security** — ✅ solved in Phase 3 (capability drops, read-only FS, internal network)
- **Seed data** — LLM generates seeds. Empty preview = bad UX (deferred)

---

## Step 6: Iteration

### What the user sees
Chat alongside preview. Writes their own or clicks a suggestion:

> [Add photos to bouquets]
> [Add a discount / promo-code system]
> [Configure order confirmation emails]

### Server
1. User message → `ChatRespondJob`
2. LLM analyzes the request → calls `StartGeneration(intent, clarifications)`. Whether this becomes 1 revision or 5 is a decision for the `CreatePlan` service, not the chat LLM
3. Generation → git commit → preview restart
4. LLM calls `SuggestPrompts` after completion

### Undo
- User: *"Undo"* → LLM calls `UndoLastChange` → `git revert` as a new revision

---

## Step 7: Export

Actions in the UI (not via chat):
- **Download ZIP**
- **Push to GitHub** — OAuth → repo → push
- (Future) **Deploy** — Kamal

---

## Architecture

```
┌───────────────────────────────────────────────────────┐
│                     WEB UI (Rails)                    │
│           Turbo Frames + Streams + Stimulus           │
├──────────────────────┬────────────────────────────────┤
│    Chat              │    Preview (iframe)            │
│    - always open     │    → {id}.preview.domain.com   │
│    - suggested       │                                │
│      prompts as      │                                │
│      clickable cards │                                │
│    Revision timeline │                                │
└──────────┬───────────┴──────────┬─────────────────────┘
           │                      │
           ▼                      ▼
┌───────────────────────────────────────────────────────┐
│                   RAILS BACKEND                       │
│                                                       │
│  Project ──has_one──→ Chat (RubyLLM)                  │
│     │                   ├── Messages                  │
│     │                   └── Tools:                    │
│     │                       StartGeneration           │
│     │                       CancelInstruction         │
│     │                       SuggestPrompts            │
│     │                       UndoLastChange            │
│     ├──has_many──→ Instructions                       │
│     │                   ├── anchor_message             │
│     │                   └── max 1 active              │
│     └──has_many──→ Revisions                          │
│                         └── linear chain              │
│                                                       │
├───────────────────────────────────────────────────────┤
│  Solid Queue                                          │
│  ChatRespondJob │ ExecuteRevisionJob │ PreviewJob     │
├───────────────────────────────────────────────────────┤
│  Solid Cable → Turbo Streams                          │
└──────────────────────┬────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
┌───────────────────┐   ┌──────────────────────────────┐
│    RubyLLM        │   │   Generation Engine          │
│    (conversation  │   │   Claude CLI (start)         │
│     + tools)      │   │   RubyLLM+tools (future)     │
└───────────────────┘   └──────────┬───────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────┐
                        │   Workspace (filesystem)     │
                        │   workspace/projects/{id}/   │
                        │   └── git repo (linear)      │
                        └──────────────────────────────┘
```

---

## Critical risks

1. **Generation time** — minutes, remediation loop may extend it. Mitigation: live progress, async chat, suggested prompts (user plans the next step while waiting).
2. **Code quality** — mitigation: verify step after every revision (bundle, migrations, herb, boot, tests) + remediation loop (max 2 fix attempts). Git history contains only verified revisions.
3. **Costs** — token tracking per Instruction. Remediation loop increases per-revision cost (max 3x in the worst case). We monitor remediation rate as a signal of prompt quality.
4. **Context between revisions** — revision notes (implementation decisions, not summary) are fed into the next revisions. App manifest gives high-level, revision notes give details.
5. **Tool call reliability** — the LLM must correctly invoke the tools. Mitigation: well-described tools, parameter validation, fallback to UI buttons.
6. **Suggested prompts quality** — bad suggestions are worse UX than no suggestions. Mitigation: good system prompts, context about project state.

---

## Left for the future

- **Rewind / branching** — architecture supports it, we don't implement it
- **Parallel instructions** — one active at a time
- **Hot reload preview** — full restart at start
- **Deployment** — Kamal / in-house, separate workstream
- **Additional tools** — e.g. `BrowsePreview` (LLM "sees" the generated app), `ShowDiff`

---

## CLI for testing

```bash
bin/generate respond   --project-id=123                  # chat response with tools
bin/generate plan      --project-id=123                  # generate plan
bin/generate execute   --project-id=123 --revision-id=1  # one revision (implement + verify)
bin/generate verify    --project-id=123                  # standalone verify (debug/dev)
bin/generate cancel    --project-id=123                  # cancel
bin/generate preview   --project-id=123                  # start preview
bin/generate full      --prompt "Flower shop..."         # full pipeline
```
