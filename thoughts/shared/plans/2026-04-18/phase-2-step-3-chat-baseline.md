# Phase 2 Step 3 — Chat Baseline (without tools) Implementation Plan

## Overview

Wire the first end-to-end user flow: a visitor lands on `/`, types an app description, gets a `Project` with an attached `Chat`, and can exchange messages with the LLM. No tools, no `StartGeneration`, no `CreatePlan` — just the plumbing that Steps 4–7 will bolt onto. RubyLLM streams the assistant reply into a Turbo Stream target in real time.

## Current State Analysis

Shipped in `b8c7ade` / `e568ef9`:

- `Project`, `Chat` (`acts_as_chat`), `Message` (`acts_as_message`), `ToolCall` (`acts_as_tool_call`), `Instruction`, `Revision` models (`app/models/*.rb`) with fixtures and model tests green.
- RubyLLM configured for OpenRouter → `anthropic/claude-haiku-4.5` (`config/initializers/ruby_llm.rb:1-7`).
- Schema has `chats.project_id` FK (`db/schema.rb:45,48`) and the full message/tool_call tables.
- `config/routes.rb` has only the health check. No controllers, no views beyond `layouts/application.html.erb`. No jobs beyond `ApplicationJob`.
- `app/tools/`, `app/agents/`, `app/prompts/`, `app/schemas/` exist as empty dirs — reserved for Step 4+.
- `spikes/roast/revision_workflow.rb` and `bin/roast` already copied (Step 1).

Gaps to close in Step 3: HTTP surface (new/create/show/post-message), `ChatRespondJob` with streaming, `Message` broadcast wiring, form + partial views, Stimulus suggestion buttons, and branch-level test coverage for every new method.

## Desired End State

A user can:

1. Visit `/` → land on `projects#new` → see a textarea with placeholder `"a flower shop page, with full payment system"` and a row of clickable suggestion buttons that prefill the textarea.
2. Submit the form → a `Project`, `Chat`, and first user `Message` are created; browser redirects to `/projects/:id`.
3. On `/projects/:id` → see their message already rendered; watch an assistant reply stream in token-by-token via Turbo Stream.
4. Type another message, post it, see it appear instantly, and get another streaming reply.
5. If `chat.ask` raises (API error, rate limit), see an assistant message whose content begins `"Error: …"` appear in the chat (polish in Step 6).

Verification: `bin/rails test` green (unit + controller + job tests cover every branch enumerated below), plus the manual walkthrough in each phase's Manual Verification.

### Key Discoveries:

- `Message.acts_as_message` + `turbo-rails` gives `Message#broadcast_append_to("chat_#{chat.id}")` OOTB — no extra include on the model (`docs/03-plans/01-phase-2-poc-generator-app.md:178`).
- Tool-call messages in RubyLLM have `content: ""` and populated `tool_calls` (`docs/03-plans/01-phase-2-poc-generator-app.md:179-180`). The streaming chunk handler must no-op when there are no content chunks — relevant for Step 4, cheap to be defensive about now.
- `chat.ask(content) { |chunk| … }` yields `RubyLLM::Chunk` objects with `.content` accumulating tokens; the final `Message` row is persisted by RubyLLM itself after the block returns.
- Project `workspace_path` is `unique, null: false`. We derive it from `id` post-create (`storage/workspaces/#{id}`), so we must persist twice or use a before_validation default that's guaranteed unique — simplest: `Project.create!(name: …, workspace_path: "pending")` then `update!(workspace_path: "storage/workspaces/#{id}")`. Or generate a UUID. We'll use the two-step pattern in a transaction for readability.
- Decision from session 2026-04-18 planning: **no `Current.project`**. The Step 4 tool will be instantiated as `StartGeneration.new(project: project)` inside `ChatRespondJob`. Step 3 pre-wires the job to derive `project` from `message.chat.project` so Step 4 only adds the tool-instantiation line.
- Routing: `MessagesController` is nested under `projects` (`POST /projects/:id/messages`). Going through `Chat` happens at the AR level (`project.chat.messages.create!`), not at the routing/controller level (see session transcript 2026-04-18 for reasoning).

## What We're NOT Doing

- **No tools.** `StartGeneration`, `SuggestPrompts`, and `CreatePlan` all arrive in Step 4. `chat.ask` is called without a `tools:` arg.
- **No instruction/revision UI.** The chat frame is the whole page. Revision status rendering lands in Step 6.
- **No system prompt.** We'll add one in Step 4 when tools need behavior discipline. Step 3's chat uses RubyLLM defaults — good enough to verify round-tripping.
- **No graceful error UX.** Rescue broadcasts a raw `"Error: …"` message. Polishing (retry button, typed error banner, event-bus wiring) is explicitly deferred to Step 6; we leave a `TODO(Step 6)` comment on the rescue.
- **No cancel/abort.** Deferred (Phase 2.5, per the Phase 2 plan's "Explicit cuts").
- **No auth / user model.** Dev-only; `Project` has no owner yet.
- **No Stimulus beyond the suggestion buttons.** Form submission uses plain Turbo.

## Implementation Approach

Three atomic commits, each green on its own. Each phase's tests cover every logical branch of every new or modified method, per the branch-coverage feedback saved in `~/.claude/projects/.../memory/feedback_test_branch_coverage.md`.

---

## Phase 1: Projects CRUD + empty chat view

### Commit
`phase 2 step 3.1: projects CRUD + empty chat view`

### Overview

Routes, `ProjectsController`, new/show views, suggestion-button Stimulus controller. Creates `Project` + `Chat` + first user `Message` in `#create`. No posting from `show` yet, no job.

### Changes Required:

#### 1. Routes
**File**: `config/routes.rb`
**Changes**: root to new, resources with new/create/show, nest (empty for now) `:messages`.

```ruby
Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#new"

  resources :projects, only: [:new, :create, :show] do
    resources :messages, only: [:create]
  end
end
```

#### 2. ProjectsController
**File**: `app/controllers/projects_controller.rb` (new)
**Changes**: `new`, `create`, `show`. `create` runs a single transaction: build project (with placeholder `workspace_path`), save, update `workspace_path` + `name` from id + description, create chat, create first user message.

```ruby
class ProjectsController < ApplicationController
  def new
    @project = Project.new
  end

  def create
    description = params.require(:project).permit(:description)[:description].to_s.strip
    if description.blank?
      @project = Project.new
      @error = "Please describe what you want to build."
      return render :new, status: :unprocessable_entity
    end

    project = Project.transaction do
      p = Project.create!(name: description.truncate(60), workspace_path: "pending-#{SecureRandom.hex(8)}")
      p.update!(workspace_path: "storage/workspaces/#{p.id}")
      chat = p.create_chat!
      chat.messages.create!(role: :user, content: description)
      p
    end

    redirect_to project
  end

  def show
    @project = Project.find(params[:id])
    @messages = @project.chat.messages.order(:created_at)
  end
end
```

#### 3. Views
**Files**: `app/views/projects/new.html.erb`, `app/views/projects/show.html.erb`, `app/views/messages/_message.html.erb` (new).

`new.html.erb`: form with textarea (placeholder `"a flower shop page, with full payment system"`), suggestion buttons wired with a Stimulus controller, submit button.

```erb
<%# app/views/projects/new.html.erb %>
<section class="w-full max-w-2xl mx-auto" data-controller="suggestions">
  <h1 class="text-3xl font-semibold mb-6">Describe the app you want to build</h1>

  <% if @error %>
    <div class="mb-4 text-red-700"><%= @error %></div>
  <% end %>

  <%= form_with model: @project, url: projects_path, class: "flex flex-col gap-4" do |f| %>
    <%= f.text_area :description,
        rows: 5,
        placeholder: "a flower shop page, with full payment system",
        class: "border rounded px-3 py-2 w-full",
        data: { suggestions_target: "textarea" } %>

    <div class="flex gap-2 flex-wrap">
      <% ["Flower shop with checkout", "Todo list with Tailwind", "Team standup tracker"].each do |suggestion| %>
        <button type="button"
                class="px-3 py-1 rounded border text-sm hover:bg-gray-100"
                data-action="click->suggestions#prefill"
                data-suggestions-value-param="<%= suggestion %>">
          <%= suggestion %>
        </button>
      <% end %>
    </div>

    <%= f.submit "Start", class: "bg-black text-white rounded px-4 py-2 w-fit" %>
  <% end %>
</section>
```

`show.html.erb`: renders the chat frame with existing messages, empty input placeholder (input form lands in Phase 2). `turbo_stream_from @project` so Phase 3 streaming works without reshaping the view.

```erb
<%# app/views/projects/show.html.erb %>
<section class="w-full max-w-3xl mx-auto">
  <%= turbo_stream_from @project %>

  <h1 class="text-2xl font-semibold mb-4"><%= @project.name %></h1>

  <div id="messages" class="flex flex-col gap-3 mb-6">
    <%= render @messages %>
  </div>

  <%# message form lands in Phase 2 %>
</section>
```

`_message.html.erb`: render per-role (user right-aligned, assistant left-aligned). Empty content renders empty (tool-call messages will get their own rendering in Step 4).

```erb
<%# app/views/messages/_message.html.erb %>
<div id="<%= dom_id(message) %>" class="flex <%= message.role == "user" ? "justify-end" : "justify-start" %>">
  <div class="max-w-[80%] rounded px-3 py-2 <%= message.role == "user" ? "bg-blue-100" : "bg-gray-100" %>">
    <div class="text-xs text-gray-500 mb-1"><%= message.role %></div>
    <div class="whitespace-pre-wrap"><%= message.content %></div>
  </div>
</div>
```

#### 4. Stimulus controller
**File**: `app/javascript/controllers/suggestions_controller.js` (new)
**Changes**: one `prefill` action that sets the textarea value from the button's `data-suggestions-value-param`.

```js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

  prefill(event) {
    this.textareaTarget.value = event.params.value
    this.textareaTarget.focus()
  }
}
```

Register in `app/javascript/controllers/index.js` if eager loading isn't in place — confirm during implementation.

#### 5. Project model — defaults friendly for the transaction
**File**: `app/models/project.rb`
**Changes**: none; the controller handles the two-step save. (If the two-step save feels ugly, an alternative is a before_validation that generates a uuid-based path and then a post-save `update_column(:workspace_path, derived)` — stick with the two-step for now.)

### Success Criteria:

#### Automated Verification:

- [x] `bin/rails test test/controllers/projects_controller_test.rb` covers, each as its own test:
  - [x] `GET /` renders `new` with status 200 and the placeholder text.
  - [x] `GET /` renders the three suggestion buttons with their labels.
  - [x] `POST /projects` with valid description creates exactly one `Project`, one `Chat`, one `Message(role: :user)` with `content == description` and redirects to `project_path(project)`.
  - [x] `POST /projects` with valid description sets `project.name == description.truncate(60)` and `project.workspace_path == "storage/workspaces/#{project.id}"`.
  - [x] `POST /projects` with two consecutive valid descriptions produces distinct `workspace_path` values (no collision).
  - [x] `POST /projects` with blank description does NOT persist a Project, re-renders `:new` with status 422, and shows an error.
  - [x] `POST /projects` with whitespace-only description is treated as blank (rejected).
  - [x] `GET /projects/:id` with a project that has no messages renders status 200 and an empty messages container.
  - [x] `GET /projects/:id` with fixture messages renders each message via `_message.html.erb`.
  - [x] `GET /projects/:id` with an unknown id returns 404.
- [ ] `bin/rails test test/system` (if system test added) or a controller-level assertion confirms the Stimulus controller is registered (script tag present). A lightweight JS unit test is overkill; we rely on manual verification.
- [x] `bin/rails routes | grep projects` shows `root`, `projects#new`, `projects#create`, `projects#show`, and `projects/:project_id/messages#create`.
- [x] `bin/rails test test/models` still green.
- [ ] `bin/dev` boots; root responds 200.

#### Manual Verification:

- [ ] Visit `/` → form renders with placeholder visible in the textarea.
- [ ] Click a suggestion button → textarea gets populated with the suggestion text.
- [ ] Submit with text → redirected to `/projects/:id`, first user message visible.
- [ ] Submit with empty textarea → form re-renders with an error message; no project created (check `Project.count`).

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to Phase 2.

---

## Phase 2: Post a message + broadcast on create

### Commit
`phase 2 step 3.2: message posting + turbo broadcast on create`

### Overview

User can post follow-up messages from `/projects/:id`. Every `Message` broadcasts an append to the project's turbo stream on create — one broadcast path that user messages (from the controller) and assistant messages (from Phase 3's job) both use. Still no assistant reply — posting a message adds it to the UI and nothing follows.

### Changes Required:

#### 1. `Message` broadcasts on create
**File**: `app/models/message.rb`
**Changes**: `after_create_commit` that appends `_message.html.erb` to the `messages` target on the project's stream.

```ruby
class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments

  after_create_commit :broadcast_append_message

  private

  def broadcast_append_message
    project = chat.project
    broadcast_append_to project, target: "messages", partial: "messages/message", locals: { message: self }
  end
end
```

Note: we broadcast to `project` (not `chat`) because the `show` view uses `turbo_stream_from @project`. Keep both ends aligned.

#### 2. MessagesController
**File**: `app/controllers/messages_controller.rb` (new)

```ruby
class MessagesController < ApplicationController
  def create
    project = Project.find(params[:project_id])
    content = params.require(:message).permit(:content)[:content].to_s.strip

    if content.blank?
      redirect_to project, alert: "Message cannot be blank." and return
    end

    project.chat.messages.create!(role: :user, content: content)
    # ChatRespondJob enqueue lands in Phase 3

    redirect_to project
  end
end
```

#### 3. Message input on `show`
**File**: `app/views/projects/show.html.erb`
**Changes**: add a form below `#messages` posting to `project_messages_path(@project)`.

```erb
<%= form_with url: project_messages_path(@project), class: "flex gap-2" do |f| %>
  <%= f.text_field :message_content_placeholder_is_unused,
      name: "message[content]",
      placeholder: "Continue the conversation…",
      class: "flex-1 border rounded px-3 py-2",
      autofocus: true %>
  <%= f.submit "Send", class: "bg-black text-white rounded px-4" %>
<% end %>
```

(The input control is recreated each page load; subsequent messages appear via the append broadcast from step 1.)

### Success Criteria:

#### Automated Verification:

- [ ] `bin/rails test test/controllers/messages_controller_test.rb` — one test per branch:
  - [ ] `POST /projects/:id/messages` with valid content creates exactly one `Message(role: :user, content: params[:message][:content])` on the project's chat.
  - [ ] `POST /projects/:id/messages` with valid content redirects to `project_path(project)`.
  - [ ] `POST /projects/:id/messages` with blank content does NOT persist a `Message` and redirects with a flash alert.
  - [ ] `POST /projects/:id/messages` with whitespace-only content is treated as blank.
  - [ ] `POST /projects/:id/messages` with an unknown project_id returns 404.
- [ ] `bin/rails test test/models/message_test.rb` — add branches:
  - [ ] `Message.create!` on a chat whose project exists broadcasts one `turbo_stream.append` targeting `messages` (assert via `assert_broadcasts` or capture turbo streams in test helper).
  - [ ] The broadcast is routed to the Message's `chat.project` stream (not the chat).
  - [ ] The broadcast renders `messages/_message.html.erb` with the message as local (structural assertion: content appears in the broadcast payload).
- [ ] Existing `projects_controller_test.rb` branches still green.
- [ ] Route `project_messages` (POST) is reachable: `bin/rails routes` shows it.

#### Manual Verification:

- [ ] On `/projects/:id`, typing a message and submitting makes it appear in the list within a few hundred ms via Turbo Stream (without a full page reload).
- [ ] The blank-input path shows a flash alert and does not append anything.
- [ ] Opening the same project in two tabs: posting from one tab makes the message appear in the other tab via the Turbo Stream subscription.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation before proceeding to Phase 3.

---

## Phase 3: `ChatRespondJob` with streaming + error rescue

### Commit
`phase 2 step 3.3: chat respond job with RubyLLM streaming`

### Overview

Enqueue `ChatRespondJob.perform_later(message.id)` from `MessagesController#create` (and from `ProjectsController#create` for the first user message). The job streams the assistant reply token-by-token into a target on the chat stream and leaves a persisted assistant `Message` behind. Errors are caught and broadcast as a plain assistant Message whose content begins `"Error: "`; a `TODO(Step 6)` comment marks this for polish.

### Changes Required:

#### 1. `ChatRespondJob`
**File**: `app/jobs/chat_respond_job.rb` (new)

```ruby
class ChatRespondJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    user_message = Message.find(message_id)
    chat = user_message.chat

    # Pre-created assistant row so the streaming target exists on the DOM
    # the instant the first chunk arrives. broadcast_append_to fires in
    # after_create_commit (Phase 2) — UI sees an empty assistant bubble.
    assistant = chat.messages.create!(role: :assistant, content: "")

    chat.ask(user_message.content) do |chunk|
      next if chunk.content.blank?
      assistant.update!(content: assistant.content + chunk.content)
      Turbo::StreamsChannel.broadcast_replace_to(
        chat.project,
        target: ActionView::RecordIdentifier.dom_id(assistant),
        partial: "messages/message",
        locals: { message: assistant }
      )
    end
  rescue StandardError => e
    # TODO(Step 6): replace this with a typed error event and proper UX.
    if assistant&.persisted?
      assistant.update!(content: "Error: #{e.message}")
      Turbo::StreamsChannel.broadcast_replace_to(
        chat.project,
        target: ActionView::RecordIdentifier.dom_id(assistant),
        partial: "messages/message",
        locals: { message: assistant }
      )
    else
      chat&.messages&.create!(role: :assistant, content: "Error: #{e.message}")
    end
  end
end
```

Rationale for pre-creating the assistant Message:
- `broadcasts_to` on Message (Phase 2) fires append on create — gives us an empty bubble to stream into.
- Chunk handler updates content + broadcasts `replace` on the same `dom_id`.
- Final state: a real `Message` row with the accumulated content. RubyLLM's own message persistence may produce a second assistant Message if `chat.ask` auto-persists — if so, delete our pre-created row in the block's `ensure` or use `chat.ask(..., persist: false)` if RubyLLM offers it. This is the single most likely gotcha in Phase 3; the job test below pins the behavior we want.

**Decision point during implementation**: after the first smoke run with the real API, confirm whether RubyLLM's `chat.ask { |chunk| }` auto-persists. Two outcomes:
- (A) RubyLLM auto-persists → drop our pre-created row; use a DOM-only "streaming target" frame appended once (not a Message), then `broadcast_append` the real assistant Message after `chat.ask` returns.
- (B) RubyLLM does not auto-persist when a block is given → our pre-created row is the persisted assistant Message; keep as above.

Both paths are 10–15 lines of difference. The automated test shape below pins behavior regardless of which path we take.

#### 2. Enqueue from controllers
**File**: `app/controllers/messages_controller.rb`
**Changes**: enqueue after create.

```ruby
message = project.chat.messages.create!(role: :user, content: content)
ChatRespondJob.perform_later(message.id)
```

**File**: `app/controllers/projects_controller.rb`
**Changes**: enqueue after the transaction.

```ruby
first_message = project.chat.messages.order(:created_at).first
ChatRespondJob.perform_later(first_message.id)
```

(Or return the message from inside the transaction — minor refactor; keep the query if it reads more cleanly.)

### Success Criteria:

#### Automated Verification:

- [ ] `bin/rails test test/jobs/chat_respond_job_test.rb` covers, each as its own test:
  - [ ] Happy path with single chunk: stub `chat.ask` to yield one chunk with `.content == "Hello"`, assert one assistant `Message` persisted with `content == "Hello"`.
  - [ ] Happy path with multiple chunks: stub `chat.ask` to yield `["Hel", "lo, ", "world"]`, assert final `Message.content == "Hello, world"`.
  - [ ] Chunk accumulation: after N chunks, exactly N `broadcast_replace_to` calls targeting the assistant's `dom_id` (assert via `assert_broadcasts` or stub + count on `Turbo::StreamsChannel`).
  - [ ] Empty chunk content: stub a chunk with `.content == ""` or `nil`; assert no broadcast_replace issued for that chunk (defensive path — relevant when Step 4 tool-call messages arrive).
  - [ ] No chunks yielded at all: stub `chat.ask` to return without yielding; assert the pre-created assistant Message remains with `content == ""` and no replace broadcasts issued (this is Step 4's tool-call scenario, harmless to pin now).
  - [ ] Rescue path — exception mid-stream: stub `chat.ask` to yield one chunk and then raise `RubyLLM::Error` (or `StandardError`); assert the assistant Message's content gets set to `"Error: #{message}"` and a final `broadcast_replace_to` runs.
  - [ ] Rescue path — exception before first chunk: stub `chat.ask` to raise immediately; assert an assistant Message exists with `content == "Error: …"`.
- [ ] `bin/rails test test/controllers/messages_controller_test.rb` adds:
  - [ ] `POST /projects/:id/messages` happy path enqueues `ChatRespondJob` with the new `message.id` (`assert_enqueued_with`).
  - [ ] `POST /projects/:id/messages` blank-content path does NOT enqueue `ChatRespondJob` (`assert_no_enqueued_jobs`).
- [ ] `bin/rails test test/controllers/projects_controller_test.rb` adds:
  - [ ] `POST /projects` happy path enqueues `ChatRespondJob` with the first user message's id.
  - [ ] `POST /projects` blank path does NOT enqueue `ChatRespondJob`.
- [ ] `bin/rails test` all green (models + controllers + job).
- [ ] No introduction of a system test with real network — all RubyLLM interaction is stubbed.

#### Manual Verification:

- [ ] `bin/dev` running; create a project with description "a todo list with Tailwind". Observe the user message, then the assistant reply streaming in token-by-token within 1–2 seconds of the first chunk.
- [ ] Post a follow-up message; streaming reply appears again.
- [ ] Break the API (unset `OPENROUTER_API_KEY` or point at a broken base URL), post a message, observe an assistant Message whose content starts with `"Error: "` appear in the chat.
- [ ] In two tabs on the same project, stream appears in both tabs (confirms the broadcast target is correct).

**Implementation Note**: After Phase 3 passes manual verification, Step 3 is closed. Proceed to Step 4.

---

## Testing Strategy

### Unit tests (models):
- `Message#broadcast_append_message`: fires on create, targets the correct stream (project), uses `messages/_message.html.erb`, passes the message as the local.
- Existing model tests (`project_test`, `chat_test`, `instruction_test`, `revision_test`) continue to pass unchanged.

### Controller tests:
- `ProjectsController`: one test per logical branch enumerated in Phase 1's Automated Verification.
- `MessagesController`: one test per branch in Phase 2 + the enqueue assertions added in Phase 3.

### Job tests:
- `ChatRespondJob`: branch coverage as listed in Phase 3. RubyLLM is stubbed; no real API calls in tests.

### Integration tests:
- None in Step 3. The full E2E (real subprocess + real API) lives in Step 7.

### Manual testing:
1. Visit `/`, submit the form, confirm redirect and visible first message.
2. Click suggestion buttons; confirm textarea prefill.
3. Post follow-up messages; confirm broadcast append.
4. Observe streaming reply token-by-token.
5. Force an error; observe `"Error: …"` assistant message.
6. Two-tab test: both tabs reflect the stream.

## Performance Considerations

- Streaming broadcasts on every chunk: at ~50 tokens/sec, that's 50 ActionCable messages/sec per active chat. Solid Cable handles this easily for single-user dev. If it becomes choppy under load, debounce chunk broadcasts at ~100ms (accumulate tokens, flush on an interval) — defer until measured.
- `broadcast_append_to` on every `Message` create fires a DB read (`chat.project`) — negligible.
- The pre-created assistant Message plus N updates per chunk = N+1 `UPDATE` statements per assistant reply. Acceptable for PoC; if the SQLite WAL contention shows up, batch updates or write to a Redis key and flush at end. Not a Step 3 concern.

## Migration Notes

No DB migrations in Step 3. All tables already exist (Phase 2 Step 2 shipped them in `b8c7ade`).

## References

- Phase 2 plan (Step 3 section): `docs/03-plans/01-phase-2-poc-generator-app.md:184-206`
- Phase 2 architectural decisions (A6, A7): `docs/03-plans/01-phase-2-poc-generator-app.md:11-29`
- Step 2 RubyLLM smoke findings (broadcasting, tool-call persistence): `docs/03-plans/01-phase-2-poc-generator-app.md:176-182`
- Workflow/Decision canon (event bus as coordination layer): `docs/02-architecture/01-workflows-and-decisions.md`
- Layer integration (RubyLLM ↔ Roast ↔ Solid Queue): `docs/02-architecture/02-layer-integration.md`
- Models shipped in `b8c7ade`: `app/models/project.rb`, `app/models/chat.rb`, `app/models/message.rb`, `app/models/instruction.rb`, `app/models/revision.rb`
- Schema: `db/schema.rb:42-140`
- RubyLLM config: `config/initializers/ruby_llm.rb:1-7`
