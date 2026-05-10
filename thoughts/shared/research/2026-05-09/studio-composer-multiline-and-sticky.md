---
date: 2026-05-09T23:01:07+02:00
researcher: Paweł Strzałkowski
git_commit: 14ecdea26f8e7280db2e68eeb52583ea729a56b5
branch: studio-tabs-and-1600-shell
repository: rails-app-generator
topic: "Studio composer — current single-line state, Build-tab DOM, scroll model, broadcast flow"
tags: [research, codebase, studio, composer, tabs, messages, turbo, stimulus, scroll]
status: complete
last_updated: 2026-05-09
last_updated_by: Paweł Strzałkowski
last_updated_note: "Added follow-up: Turbo Stream append mechanics (turbo-rails 2.0.23 source), scroll-anchoring browser matrix (incl. iOS Safari gap), scroll-behavior + scrollIntoView, autofocus + form-replace lifecycle, field-sizing browser support, sticky-bottom + iOS keyboard (dvh / visualViewport)."
---

# Research: Studio composer — current single-line state, Build-tab DOM, scroll model, broadcast flow

**Date**: 2026-05-09T23:01:07+02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: 14ecdea26f8e7280db2e68eeb52583ea729a56b5
**Branch**: studio-tabs-and-1600-shell
**Repository**: rails-app-generator

## Research Question

Document the current state of the studio composer and the surrounding Build-tab DOM/scroll/broadcast machinery, in preparation for a planned change that:
1. Turns the prompt input into a multiline textarea (2 rows by default, growing up to 5 rows as the user adds newlines).
2. Makes the composer sticky to the bottom of the viewport while the Build-tab conversation is being scrolled.
3. Adds a "scroll to bottom" affordance (a down arrow above the composer, horizontally centered) that appears whenever the conversation is not already scrolled to its end.

This research only describes what exists today; no recommendations.

## Summary

- The studio composer is a **single-line `<input type="text">`** rendered by `app/views/messages/_form.html.erb`. It uses `f.text_field`, the design-system class `.field-input`, and (after the surface-lift commit `349e557`) sits inside a `.composer` paper-0 card with `:focus-within` ring on the wrapper. There is no textarea, no auto-grow, no row count.
- The composer lives **inline in the normal document flow**, immediately below the `#messages` div, both wrapped by the Build pane (`#pane_build`). The Build pane is the first of three `data-tabs-target="pane"` siblings; the tabs Stimulus controller toggles their `display` attribute.
- The page **does not own a scroll container** for the conversation. `#messages` has no `overflow`, no `max-height`, no fixed/absolute positioning. The whole `<section style="max-width: 1600px; margin: 0 auto;">` is part of normal `<main>` layout under `body.app-shell`, and the document body is the scroller.
- The only `position: sticky` rule in the app today is on `.app-nav` (the top nav). There is no scroll-listener, no `scrollTo` / `scrollIntoView` / `scrollHeight` / `IntersectionObserver` use anywhere in `app/javascript`, `app/views`, `app/helpers`, `app/controllers`, `app/models`, or `app/jobs`.
- New messages reach the page via two Turbo paths: (a) the `MessagesController#create` action returns a `turbo_stream.replace` that re-renders the empty form, and (b) `Message#after_create_commit` broadcasts an *append* to a Turbo Stream target named `"messages"` on the `chat.project` channel. The user's bubble and the assistant's bubble both arrive through the broadcast path; nothing else mutates `#messages`.
- A textarea pattern *does* exist elsewhere: `/projects/new` (`app/views/projects/new.html.erb`) uses `f.text_area rows: 5, class: "field-textarea"`. The `.field-textarea` CSS at `app/assets/tailwind/application.css:399-421` shares its rule block with `.field-input` and adds `resize: vertical; min-height: 96px;`. There is no JavaScript-driven auto-grow.
- The Stimulus inventory is small: `tabs_controller.js`, `suggestions_controller.js`, `dismiss_controller.js`, `hello_controller.js`. None watches scroll. `suggestions_controller.js` happens to declare a `textarea` target, but it is bound only on `/projects/new` and is unrelated to the studio composer.

## Detailed Findings

### Studio shell — Build tab DOM

**File**: `app/views/projects/show.html.erb:1-60`

The whole studio screen is one `<section>` with `max-width: 1600px; margin: 0 auto;`. Inside it:

```
<section style="max-width: 1600px; margin: 0 auto;">
  <%= turbo_stream_from @project %>           # subscribes to Turbo broadcasts
  <div class="eyebrow">studio · …</div>
  <h1 class="h-section">@project.name</h1>
  <%= render "shared/chat_notice" %>          # error strip, Stimulus dismiss

  <div data-controller="tabs" data-tabs-active-value="build">
    <%= render "tab_nav" %>                   # the three .tab-button elements

    <div id="pane_build"   …  data-tabs-target="pane"  data-tab-name="build">
      <div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">
        <% @chat_events.each do |event| %>
          # Message → render messages/message
          # Instruction → render instructions/status_row
        <% end %>
      </div>
      <div style="margin-top: 16px;">
        <%= render "messages/form", project: @project %>
      </div>
    </div>

    <div id="pane_preview"  … data-tabs-target="pane"  data-tab-name="preview"  style="display: none;">
      <div id="active_revisions">…</div>
      <%= render "previews/pane", project: @project %>
    </div>

    <div id="pane_export"  … data-tabs-target="pane"  data-tab-name="export"  style="display: none;">
      <%= render "github_exports/pane", project: @project %>
    </div>
  </div>
</section>
```

Three things to note in this block:
1. `#messages` and the composer wrapper are **siblings** under `#pane_build`. They are not wrapped in any container with its own scroll geometry — both share the page's natural document flow.
2. The Build pane's only own attribute styling is `tabindex="0"` and the tabs data-attributes; there is no padding, height, or overflow on it.
3. The Preview and Export panes are inert (`display: none`) until activated. The tabs controller never adds them to or removes them from the DOM — only toggles their `style.display`.

### Tabs controller — what shows the Build pane

**File**: `app/javascript/controllers/tabs_controller.js:1-61`

```javascript
static targets = ["tab", "pane"]
static values  = { active: { type: String, default: "build" } }

render() {
  const active = this.activeValue
  this.tabTargets.forEach((el) => {
    const isActive = el.dataset.tabName === active
    el.classList.toggle("is-active", isActive)
    el.setAttribute("aria-selected", isActive ? "true" : "false")
    el.setAttribute("tabindex", isActive ? "0" : "-1")
  })
  this.paneTargets.forEach((el) => {
    el.style.display = (el.dataset.tabName === active) ? "" : "none"
  })
}
```

`render()` runs on `connect()` and on every `activeValueChanged()`. It writes `style.display = ""` to the active pane and `"none"` to inactive ones — there is no `is-active` class on panes, no IntersectionObserver, no event broadcast on tab switch. Anything else that needs to know "Build is active" must read `data-tabs-active-value` from the tabs controller's root element, the active class on `.tab-button.is-active`, or `data-tab-name` on whichever pane has `style.display !== "none"`.

`switch(event)` is bound via `data-action="click->tabs#switch keydown->tabs#keydown"` on each tab button (see `app/views/projects/_tab_nav.html.erb:28`). `keydown` cycles ArrowLeft / ArrowRight / Home / End across tabs.

### Composer — the prompt itself

**File**: `app/views/messages/_form.html.erb:1-9`

```erb
<%= form_with url: project_messages_path(project), id: dom_id(project, :message_form), class: "composer" do |f| %>
  <%= f.text_field :content,
      id: "message_content_input",
      name: "message[content]",
      placeholder: "Continue the conversation…",
      class: "field-input",
      autofocus: true %>
  <%= f.submit "Send", class: "btn btn--primary" %>
<% end %>
```

- `f.text_field` → `<input type="text">`. Single-line. Pressing Return submits the form.
- The form's DOM id is `dom_id(project, :message_form)` (e.g., `message_form_project_42`). `MessagesController#create` targets exactly this id when it returns the Turbo stream replace.
- The input's id `message_content_input` is referenced nowhere in the JS today.
- `autofocus: true` runs once at page load.

**File**: `app/assets/tailwind/application.css:399-421` (the global field rules — left untouched in the surface-lift commit)

```css
.field-input,
.field-textarea {
  font-family: var(--hi-font-sans);
  font-size: 22px;
  line-height: 1.5;
  color: var(--fg);
  background: var(--paper-0);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm);
  padding: 8px 12px;
  width: 100%;
  outline: none;
  transition: border-color var(--dur-fast) var(--ease-standard),
              box-shadow var(--dur-fast) var(--ease-standard);
}
.field-input::placeholder,
.field-textarea::placeholder { color: var(--fg-faint); }
.field-input:focus,
.field-textarea:focus {
  border-color: var(--accent);
  box-shadow: var(--focus-ring);
}
.field-textarea { resize: vertical; min-height: 96px; }
```

Notice that `.field-input` and `.field-textarea` share one rule block — the only textarea-specific addition is `resize: vertical; min-height: 96px;`.

**File**: `app/assets/tailwind/application.css:638-661` (composer rules after the surface-lift commit `349e557`)

```css
.composer {
  display: flex;
  gap: 8px;
  align-items: stretch;
  background: var(--paper-0);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-md);
  padding: 6px;
  transition: border-color var(--dur-fast) var(--ease-standard),
              box-shadow var(--dur-fast) var(--ease-standard);
}
.composer:focus-within {
  border-color: var(--accent);
  box-shadow: var(--focus-ring);
}
.composer .field-input {
  flex: 1;
  background: transparent;
  border: 0;
  padding: 8px 10px;
}
.composer .field-input:focus {
  border-color: transparent;
  box-shadow: none;
}
```

The composer is a **flex row** with `align-items: stretch`. Today both children (the input and the Send button) are single-row, so cross-axis stretch is inert. The card carries the visible frame; the input is transparent + borderless inside it. Focus is on the wrapper via `:focus-within`.

The composer wrapper currently has only the `.composer` class — no extra DOM hooks, no Stimulus controller, no data attributes. The form `id` is on the `<form>` itself.

### Conversation messages — render and update

**File**: `app/views/messages/_message.html.erb:1-15`

```erb
<div id="<%= dom_id(message) %>" class="<%= message_row_class(message) %>">
  <% if message.visible_in_chat? %>
    <div class="msg-bubble">
      <div class="msg-role"><%= message.role %></div>
      <% if message.role == "assistant" && message.tool_calls.any? %>
        <div class="msg-pill"><%= tool_call_pill_text(message) %></div>
      <% end %>
      <% if message.content.to_s.strip.present? %>
        <div class="msg-body"><%= message.content %></div>
      <% end %>
    </div>
  <% end %>
</div>
```

`message_row_class` (in `app/helpers/messages_helper.rb`) returns `"msg msg-user"` or `"msg msg-asst"` (or `"hidden"` for invisible messages). `.msg` is `display: flex` with role-specific `justify-content` (right for user, left for assistant). The bubble itself sits inside that flex row.

**File**: `app/assets/tailwind/application.css:586-617` (chat bubble rules — current values after the surface-lift commit `349e557`)

```css
.msg { display: flex; }
.msg-user { justify-content: flex-end; }
.msg-asst { justify-content: flex-start; }

.msg-bubble {
  max-width: 80%;
  padding: 10px 14px;
  border-radius: var(--radius-md);
  border: 1px solid var(--border-strong);
  background: var(--paper-0);
}
.msg-user .msg-bubble {
  background: var(--bg-inverse);
  color: var(--fg-on-accent);
  border-color: transparent;
}
.msg-user .msg-role { display: none; }
.msg-user .msg-body { color: var(--fg-on-accent); }
.msg-role { font-family: var(--hi-font-mono); font-size: 16px; … }
.msg-body { color: var(--fg); white-space: pre-wrap; line-height: 1.55; }
.msg-pill { … blinking accent dot via ::before … }
```

Status rows (`app/views/instructions/_status_row.html.erb:1-16`) reuse `.msg .msg-asst` + `.msg-bubble` + `.msg-pill`, so they inherit the assistant-bubble surface for free.

### Conversation scroll model

`#messages` itself has no overflow/height styling — only Tailwind utility classes (`flex flex-col`) plus inline `gap: 12px; margin-bottom: 16px;`. Its parent `#pane_build` has no constraints. The chain up:

- `body` (no inline styles besides the global rule at `app/assets/tailwind/application.css:110-119`: `background: var(--bg); color: var(--fg); font-family: …`).
- `body.app-shell` → `min-height: 100vh; display: flex; flex-direction: column;` (`app/assets/tailwind/application.css:190-195`).
- `nav.app-nav` → `position: sticky; top: 0; z-index: 30; height: 60px;` (`app/assets/tailwind/application.css:197-204`). This is the **only** sticky element in the codebase.
- `<main class="w-full" style="padding: 24px;">` (`app/views/layouts/application.html.erb:47`).
- `<section style="max-width: 1600px; margin: 0 auto;">` (`app/views/projects/show.html.erb:1`).

Net effect: the document body is the scroll root. As messages accumulate, the page grows taller; the user scrolls the whole page. The composer is **not** anchored — it just sits at the bottom of `#pane_build` and scrolls with the rest of the content. The top nav is the only fixed-position element on screen.

A grep for `scrollTo|scrollIntoView|scrollHeight|IntersectionObserver` across `app/javascript`, `app/views`, `app/helpers`, `app/controllers`, `app/models`, `app/jobs` returns no matches.

A grep for `position: sticky|overflow:|fixed` across `app/assets/tailwind/application.css` returns:
- `position: sticky` only at `app/assets/tailwind/application.css:198` (`.app-nav`).
- `overflow: hidden` for `.project-card__name`, `.preview-pane`, `.preview-pane__url` (text-overflow ellipsis, container clipping).
- `overflow: auto` only at `.preview-pane__error` (`app/assets/tailwind/application.css:737` — error log scroller).

There is no scroll container, no auto-scroll-on-broadcast, no scroll listener anywhere in the studio chain.

### How a new message appears in `#messages`

The flow that mutates `#messages` after the page has loaded:

1. **User submits form** (`app/views/messages/_form.html.erb`). Turbo intercepts the submit (Hotwire is on by default).
2. **`MessagesController#create`** (`app/controllers/messages_controller.rb:4-22`) accepts the message, persists `Message.create!(role: :user, content: …)`, then enqueues `ChatRespondJob.perform_later(message.id)`.
3. The controller responds with `turbo_stream.replace(dom_id(@project, :message_form), partial: "messages/form", locals: { project: @project })` — i.e., it replaces the *form*. The replacement re-renders the empty form, which clears the input. The user's message itself is **not** appended by the controller's response; it is appended by the broadcast in step 4.
4. **`Message#after_create_commit :broadcast_append_message`** (`app/models/message.rb:5-24`) fires:
   ```ruby
   broadcast_append_later_to chat.project,
     target: "messages",
     partial: "messages/message",
     locals: { message: self }
   ```
   This delivers a `<turbo-stream action="append" target="messages">` payload to the page (which subscribed via `<%= turbo_stream_from @project %>` at `app/views/projects/show.html.erb:2`). Turbo appends the rendered `_message.html.erb` to `#messages`.
5. Subsequent message updates (e.g., assistant's content streaming in chunks, tool-call attachments) trigger `Message#after_update_commit :broadcast_replace_message` which replaces the `<div id="<%= dom_id(message) %>">` element in place.

Because the page is the scroller and nothing in the broadcast path manipulates scroll, **the viewport position is left wherever the user last left it** when a new message arrives.

### Existing textarea pattern (for reference)

**File**: `app/views/projects/new.html.erb:1-41`

```erb
<section style="max-width: 1280px; margin: 0 auto;" data-controller="suggestions">
  …
  <%= form_with model: @project, url: projects_path, class: "flex flex-col", style: "gap: 16px;" do |f| %>
    <div>
      <label class="field-label" for="project_description">Project description</label>
      <%= f.text_area :description,
          rows: 5,
          id: "project_description",
          placeholder: "a flower shop page, with full payment system",
          class: "field-textarea",
          data: { suggestions_target: "textarea" } %>
    </div>
    <div>
      <div class="eyebrow" style="margin-bottom: 8px;">starting points</div>
      <div class="composer-suggestions" style="margin-top: 0;">
        <% [ "Flower shop with checkout", "Todo list with Tailwind", "Team standup tracker" ].each do |suggestion| %>
          <button type="button"
                  class="suggestion-chip"
                  data-action="click->suggestions#prefill"
                  data-suggestions-value-param="<%= suggestion %>">
            <%= suggestion %>
          </button>
        <% end %>
      </div>
    </div>
    <%= f.submit "Start", class: "btn btn--primary", style: "align-self: flex-start;" %>
  <% end %>
</section>
```

This is the only `<textarea>` rendered in the app's views. It is fixed at `rows: 5`, uses `.field-textarea`, has user-vertical resize via the CSS, and ships no JavaScript-driven auto-grow. The `data-suggestions-target="textarea"` hook is for `suggestions_controller.js#prefill`, which fills the field when a chip is clicked.

### Stimulus inventory

`app/javascript/controllers/`:

- `tabs_controller.js` — toggles the studio tabs (see above).
- `suggestions_controller.js` (`app/javascript/controllers/suggestions_controller.js:1-11`):
  ```javascript
  export default class extends Controller {
    static targets = ["textarea"]
    prefill(event) {
      this.textareaTarget.value = event.params.value
      this.textareaTarget.focus()
    }
  }
  ```
  Bound only on `/projects/new`. Its `textarea` target name is incidental — the controller would work on any element with a `value` property. It is not loaded on `/projects/:id`.
- `dismiss_controller.js` (`app/javascript/controllers/dismiss_controller.js:1-7`): `close()` does `this.element.remove()`. Used by `_chat_notice.html.erb`.
- `hello_controller.js` — Rails default scaffold sample.
- `index.js` eager-loads everything via `eagerLoadControllersFrom("controllers", application)` (`app/javascript/controllers/index.js:1-4`).
- `application.js` boots Stimulus.

There is no scroll-watcher, no resize-observer, no message-list controller.

### Layout chain summary

```
<html>
  <body class="app-shell">                             ← display: flex; flex-direction: column; min-height: 100vh
    <nav class="app-nav">                              ← position: sticky; top: 0
    <main class="w-full" style="padding: 24px;">       ← page scroll happens here / on body
      [optional] notice-strip / alert
      <%= yield %>                                     ← projects/show.html.erb renders below
        <section style="max-width: 1600px; margin: 0 auto;">
          <%= turbo_stream_from @project %>
          eyebrow + h1
          <%= render "shared/chat_notice" %>
          <div data-controller="tabs" data-tabs-active-value="build">
            <%= render "tab_nav" %>                    ← .tab-nav (full-width, three thirds)
            <div id="pane_build">
              <div id="messages" class="flex flex-col">
                # one row per message / instruction
              </div>
              <div style="margin-top: 16px;">
                <%= render "messages/form" %>          ← .composer card with .field-input + Send button
              </div>
            </div>
            <div id="pane_preview" style="display: none;">…</div>
            <div id="pane_export"  style="display: none;">…</div>
          </div>
        </section>
    </main>
  </body>
</html>
```

## Code References

- `app/views/projects/show.html.erb:1-60` — studio shell, tabs container, `#pane_build` with `#messages` + composer.
- `app/views/projects/_tab_nav.html.erb:1-33` — three `.tab-button` elements with `data-tabs-target="tab"` and `data-tab-name`.
- `app/javascript/controllers/tabs_controller.js:1-61` — sole tab activation logic; toggles `style.display` on each `data-tabs-target="pane"`.
- `app/views/messages/_form.html.erb:1-9` — composer markup (single-line `text_field`, `.field-input`, Send button, `class="composer"`).
- `app/views/messages/_message.html.erb:1-15` — bubble markup (`.msg`, `.msg-bubble`, `.msg-role`, `.msg-body`, optional `.msg-pill`).
- `app/views/instructions/_status_row.html.erb:1-16` — build status row using the same `.msg .msg-asst` surface.
- `app/helpers/messages_helper.rb` — `message_row_class`, `tool_call_pill_text`.
- `app/models/message.rb:5-33` — `after_create_commit :broadcast_append_message` to target `messages`; `after_update_commit :broadcast_replace_message`.
- `app/controllers/messages_controller.rb:4-22` — submit-handler that returns `turbo_stream.replace` of the form partial.
- `app/views/projects/new.html.erb:14-40` — only `f.text_area` in the views; uses `.field-textarea` with `rows: 5` and `data-suggestions-target`.
- `app/javascript/controllers/suggestions_controller.js:1-11` — only controller that touches a textarea; bound only on `/projects/new`.
- `app/javascript/controllers/dismiss_controller.js:1-7` — used by `_chat_notice.html.erb`, unrelated to composer.
- `app/views/layouts/application.html.erb:27-66` — `body.app-shell` flex column, sticky `app-nav`, `<main>` with `padding: 24px`.
- `app/assets/tailwind/application.css:110-119` — body baseline (no overflow rule).
- `app/assets/tailwind/application.css:190-204` — `.app-shell` flex column + `.app-nav` sticky (only sticky element).
- `app/assets/tailwind/application.css:240-289` — `.tab-nav` + `.tab-button` (no bottom rule on the strip; each tab draws its own).
- `app/assets/tailwind/application.css:399-421` — `.field-input` / `.field-textarea` shared rules; `.field-textarea { resize: vertical; min-height: 96px; }`.
- `app/assets/tailwind/application.css:586-617` — chat bubble rules (paper-0 default, `.msg-user .msg-bubble` inverse).
- `app/assets/tailwind/application.css:638-661` — `.composer` paper-0 card with `:focus-within` ring; scoped `.composer .field-input` overrides (transparent, borderless, no own focus ring).
- `app/assets/tailwind/application.css:737` — single `overflow: auto` rule, on `.preview-pane__error` (unrelated).
- `config/importmap.rb:1-8` — Hotwire stack: turbo-rails, stimulus, stimulus-loading, controllers eager-loaded.

## Architecture Documentation

**Design system** — Hifumi tokens. All composer/bubble/tab colors come from CSS variables defined in `:root` at `app/assets/tailwind/application.css:9-105` (`--paper-0/50/100/…`, `--ink-100/200/800`, `--accent`, `--fg-on-accent`, `--bg-inverse`, `--border-strong`, `--rule`, `--focus-ring`, `--radius-md`, `--dur-fast`, `--ease-standard`). New surfaces in this area are expected to draw from these tokens (see `CLAUDE.md` "Design system: Hifumi" + `docs/02-architecture/04-design-system.md`).

**Hotwire stack** — Turbo for stream broadcasts and form responses; Stimulus for client-side behavior. Controllers live under `app/javascript/controllers/` and are eager-loaded by `controllers/index.js`. Each Stimulus controller is single-purpose and small (≤ 60 lines).

**Tabs pattern** — single-root WAI-ARIA tabs controller at `app/javascript/controllers/tabs_controller.js`. Pane visibility is `style.display = "" | "none"`; `is-active` only goes on the tab button. The active-value is held in `this.activeValue` (Stimulus value, default `"build"`).

**Message broadcast pattern** — `acts_as_message` (RubyLLM) on `Message`; per-project Turbo Stream channel via `<%= turbo_stream_from @project %>` on the show view. `after_create_commit` appends to `target: "messages"`, `after_update_commit` replaces by `dom_id`. The user's own message is appended via the same broadcast path, not via the form's Turbo Stream response (which only replaces the form to clear it).

## Historical Context (from thoughts/)

- `./thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md` — the contrast research that drove the surface-lift plan; documents the pre-lift values (paper-0 user vs paper-50 assistant on paper-100 page, ΔL ~1.5–2.5/100) that motivated the inverse-user / paper-0-assistant / paper-0-composer family.
- `./thoughts/shared/plans/2026-05-09/studio-tabs-and-chat-bubble-lift.md` — the implementation plan that just shipped (commit `349e557`); explicitly out-of-scope items include "no suggestion-chip strip on the studio composer" and "no asymmetric bubble corners".
- `./thoughts/shared/plans/2026-05-08/studio-tabs-and-1600-shell.md` — origin of the three-tab studio layout and the 1600px shell.
- `./thoughts/shared/plans/2026-05-09/typography-ramp-bump.md` — typography bumps that affect the composer's font-size (22px on `.field-input`).
- `./thoughts/shared/research/2026-05-09/typography-font-size-inventory.md` — full inventory of font-sizes (relevant if the composer's vertical metrics need to be re-derived for a 2-row textarea).

## Related Research

- `./thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md` — surface contrast analysis preceding the lift plan.
- `./thoughts/shared/research/2026-05-09/typography-font-size-inventory.md` — font-size ramp.

## Open Questions

- None for the documentation goal; the area is fully mapped. Anything beyond mapping (e.g., where a sticky-composer container should live in the DOM, how a scroll-watcher would coexist with Turbo broadcasts) is out of scope per the research framing.

## Follow-up Research 2026-05-09T23:18+02:00

Documenting the canonical browser/library behaviors that surround the planned change. Source-of-truth split: where possible, claims are verified against the local `turbo-rails 2.0.23` source (`/Users/pawel/.frum/versions/4.0.2/lib/ruby/gems/4.0.0/gems/turbo-rails-2.0.23/app/assets/javascripts/turbo.js`, the file the importmap pins as `turbo.min.js`); browser-side claims are verified against MDN / WHATWG / caniuse / WebKit release notes.

### F1. Turbo Stream `append` action — DOM mechanics, no scroll involvement

**Local source** (`turbo.js:5108-5156`, `turbo-rails 2.0.23`):

```javascript
const StreamActions = {
  append() {
    this.removeDuplicateTargetChildren();
    this.targetElements.forEach((e => e.append(this.templateContent)));
  },
  // …
};
```

The `append` action is exactly two operations: (1) `removeDuplicateTargetChildren()` walks the target's existing children and deletes any whose `id` matches an `id` in the new template (so a rebroadcast of the same `Message` would replace, not duplicate, the existing `<div id="message_42">`); (2) the new template content is appended via the standard DOM `Element.append()`. No `scrollIntoView`, no `scrollTo`, no class toggle.

**Local source** (`turbo.js:5161-5183`, `5253-5260`): each `<turbo-stream>` is a custom element. Its `connectedCallback()` calls `this.render()`, which:

```javascript
async render() {
  return this.renderPromise ??= (async () => {
    const event = this.beforeRenderEvent;          // "turbo:before-stream-render"
    if (this.dispatchEvent(event)) {
      await nextRepaint();
      await event.detail.render(this);             // performs the actual mutation
    }
  })();
}
```

The event is `turbo:before-stream-render`, **bubbles**, **cancelable**, with `detail = { newStream: this, render: StreamElement.renderElement }`. It fires *before* the DOM mutation. The render function (`event.detail.render`) can be reassigned in a listener to wrap or replace the action. A grep of `turbo.js` confirms this is the only stream-side event — there is no `turbo:after-stream-render`. (Other Turbo events — `turbo:before-render`, `turbo:render`, `turbo:frame-render`, `turbo:before-frame-render`, `turbo:morph`, `turbo:morph-element` — are tied to page navigation or frame rendering, not to broadcast streams.)

**Confirmation** that there is no Turbo-side autoscroll for stream actions: [Turbo Streams handbook](https://turbo.hotwired.dev/handbook/streams) lists no autoscroll attribute; the autoscroll mechanism is documented exclusively under [Turbo Frames reference](https://turbo.hotwired.dev/reference/frames) and exists only on `<turbo-frame>`.

### F2. `<turbo-frame>` autoscroll — exists, but not relevant here

**Local source** (`turbo.js:1642-1656`):

```javascript
scrollFrameIntoView() {
  if (this.currentElement.autoscroll || this.newElement.autoscroll) {
    const element = this.currentElement.firstElementChild;
    const block    = readScrollLogicalPosition(this.currentElement.getAttribute("data-autoscroll-block"), "end");
    const behavior = readScrollBehavior(this.currentElement.getAttribute("data-autoscroll-behavior"), "auto");
    if (element) {
      element.scrollIntoView({ block, behavior });
      return true;
    }
  }
  return false;
}
```

This runs only when a `<turbo-frame>` finishes rendering; defaults are `block: "end"`, `behavior: "auto"` (so it respects `scroll-behavior: smooth` on the scroll root). The studio screen does not use `<turbo-frame>` — it broadcasts via `<%= turbo_stream_from @project %>` and `Message#after_create_commit broadcast_append_later_to`. So this code path is dormant for the conversation today.

### F3. Scroll anchoring on append below the viewport

When new content is appended *below* the current viewport — the case for `target: "messages"` near the page bottom — there is nothing to anchor (anchoring corrects for content inserted *above* the viewport). The page simply grows downward; the user's scroll position stays put. This is browser-default behavior independent of `overflow-anchor`. The CSS [`overflow-anchor`](https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-anchor) defaults to `auto` (anchoring enabled) and is supported in Chrome 56+, Edge 79+, and Firefox 66+ for the *above-viewport* case.

iOS Safari is the holdout: the [WebKit overflow-anchor implementation](https://bugs.webkit.org/show_bug.cgi?id=171099) shipped in [Safari Technology Preview 238 (Feb 26, 2026)](https://webkit.org/blog/17848/release-notes-for-safari-technology-preview-238/) but had not appeared in stable iOS Safari at the time of this research. [caniuse](https://caniuse.com/css-overflow-anchor) reports ~78.6% global coverage, with iOS Safari being the gap. The append-below-viewport case still works on iOS because no anchoring is required for content added below.

There is no `overflow-anchor` rule anywhere in `app/assets/tailwind/application.css` — the project relies on browser defaults.

### F4. `scroll-behavior: smooth` + `Element.scrollIntoView()`

`scrollIntoView()` with no arguments resolves `behavior` from the computed `scroll-behavior` of the scroll container. So `html { scroll-behavior: smooth }` would make every default `scrollIntoView()` animate. Explicit `scrollIntoView({ behavior: "smooth", block: "end" })` always animates regardless of CSS.

iOS Safari ships full `scrollIntoView` support from iOS 16; the `behavior: "smooth"` option on `ScrollIntoViewOptions` was added at Safari 15.4 (per [mdn/browser-compat-data #22889](https://github.com/mdn/browser-compat-data/issues/22889)). Compat: [caniuse scrollintoview](https://caniuse.com/scrollintoview), [MDN scrollIntoView](https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollIntoView).

The project's CSS sets neither `scroll-behavior` nor `scroll-padding`. The body is the scroll root (see chain in §"Conversation scroll model" above).

### F5. `autofocus` does not re-fire on Turbo Stream form replace

The HTML `autofocus` attribute is processed during element insertion, but the WHATWG spec ([§ the-autofocus-attribute](https://html.spec.whatwg.org/multipage/interaction.html#the-autofocus-attribute)) only runs the focus step if no autofocus has yet been processed in the top-level browsing context's history entry. In practice, an `autofocus` attribute on an element inserted by `turbo_stream.replace(...)` does not focus the element in any major browser.

This matters for the studio composer because `MessagesController#create` returns exactly such a stream (`app/controllers/messages_controller.rb:9, 19`):

```ruby
turbo_stream.replace(ActionView::RecordIdentifier.dom_id(@project, :message_form),
                     partial: "messages/form",
                     locals: { project: @project })
```

The replacement re-renders `_form.html.erb`, which carries `autofocus: true` on the input (`app/views/messages/_form.html.erb:7`). The browser does not re-focus — the input's autofocus only fires on the initial page load. After every send today the cursor leaves the composer.

The Hotwire-community workaround is a Stimulus controller that calls `.focus()` in `connect()` — see the [Hotwire Discuss thread "autofocus an input after loading via stream"](https://discuss.hotwired.dev/t/autofocus-an-input-after-loading-via-stream/3020). The studio currently has no such controller; the only `.focus()` calls in this codebase are inside `tabs_controller.js` (after a tab switch) and `suggestions_controller.js` (after a chip click). Neither re-focuses the composer after a form replace.

### F6. Auto-grow textarea options

**CSS-only: `field-sizing: content`.** Auto-sizes a `<textarea>` to its content with no JavaScript. Browser support, May 2026:

- Chrome / Edge: shipped in Chrome 123 (March 2024).
- Safari: shipped in Safari 26.2.
- Firefox: not supported as of Firefox 153 (May 2026).

Sources: [MDN field-sizing](https://developer.mozilla.org/en-US/docs/Web/CSS/field-sizing), [caniuse field-sizing:content](https://caniuse.com/mdn-css_properties_field-sizing_content). Not Baseline; the Firefox gap means it can't carry an experience alone if Firefox is in scope.

**JS controlled-rows pattern.** The conventional pattern for "grow from N rows up to M rows" is:

1. Render `<textarea rows="2">`.
2. On each `input` event, set `el.rows = Math.min(maxRows, Math.max(minRows, contentLineCount))`, where `contentLineCount` is computed from `el.value.split("\n").length` (newlines only — does not account for soft-wrapped wrap rows) or via a hidden `<div>` mirror.

The project ships no such controller today. Stimulus + the existing `.field-textarea { resize: vertical; min-height: 96px; }` rule (`app/assets/tailwind/application.css:421`) is the only textarea-related styling; that rule allows manual resize but does not auto-grow.

### F7. Sticky-bottom composer + iOS soft keyboard

In 2026 the canonical pattern for "composer pinned to the bottom of the visible viewport, behaves under the iOS keyboard" uses the `dvh` viewport unit:

- `100dvh` (dynamic viewport height) tracks the visual viewport; when iOS Safari opens the keyboard, the visual viewport shrinks and `100dvh` shrinks with it. A flex-column layout sized to `min-height: 100dvh` — or a `position: sticky; bottom: 0` composer inside such a column — naturally rides above the keyboard.
- `100vh` is the *large* viewport height (pre-keyboard) on iOS Safari, which is why `position: fixed; bottom: 0` historically gets buried under the keyboard.
- Where `dvh` alone is insufficient (e.g. an inner `position: fixed`), the [`window.visualViewport` API](https://developer.mozilla.org/en-US/docs/Web/API/VisualViewport) is the fallback: listen to `resize`, read `visualViewport.height` and `visualViewport.offsetTop`, and reposition the element. Background: ["Fix mobile keyboard overlap with visualViewport"](https://www.franciscomoretti.com/blog/fix-mobile-keyboard-overlap-with-visualviewport).
- The `<meta name="viewport" content="… interactive-widget=resizes-content">` token (Android Chrome 108+) makes Chrome resize the layout viewport when the keyboard opens. iOS Safari ignores it.
- Known iOS 26-beta regression: `visualViewport.height` / `offsetTop` don't fully revert after the keyboard is dismissed and the page is scrolled — [WebKit bug 297779](https://bugs.webkit.org/show_bug.cgi?id=297779).

The project's CSS uses `100vh` only at `app/assets/tailwind/application.css:191` (`.app-shell { min-height: 100vh; }`), and the layout's viewport meta is the unmodified Rails default (`app/views/layouts/application.html.erb:5`: `width=device-width,initial-scale=1`, no `interactive-widget` token). No `dvh`, `svh`, or `lvh` units are used anywhere.

### F8. Cross-cutting: what the page already does after a broadcast append

Putting F1-F3 + the existing model code together, the post-append timeline today is:

1. Worker enqueued by `Message#after_create_commit broadcast_append_message` (`app/models/message.rb:16-24`) renders `messages/_message.html.erb` and pushes it down the per-project Action Cable channel (with `solid_cable` in dev — see memory `project_dev_cable_solid`).
2. The `<turbo-stream-source>` element added by `<%= turbo_stream_from @project %>` (`show.html.erb:2`) receives the stream and inserts a fresh `<turbo-stream action="append" target="messages">` element into the DOM.
3. That element's `connectedCallback` fires `turbo:before-stream-render`, awaits `nextRepaint`, then calls `e.append(content)` on `#messages`.
4. The browser appends the new `<div id="message_42" class="msg msg-asst">…</div>`. Document body grows. **The user's scroll position is not changed.** No `:focus-within`, no smooth scroll, no event after the mutation.
5. If the bubble is the assistant's and content is being filled in chunks via Solid Queue → broadcast_replace, step 4 re-runs as `replace` (same flow, no scroll) for the same `dom_id`.

For the planned change, the consequence chain looks like: the sticky composer must own its own scroll-bottom signal because Turbo provides none; any "scroll to bottom" affordance has to be wired to a JS scroll listener (or `IntersectionObserver` against a sentinel); and the auto-focus restoration after `MessagesController#create`'s form-replace is a separate latent issue (autofocus does not re-fire — see F5) that the multiline change will inherit.

## References (added in follow-up)

- `app/views/layouts/application.html.erb:5` — viewport meta tag.
- `app/assets/tailwind/application.css:191` — only `100vh` reference (`.app-shell`).
- `/Users/pawel/.frum/versions/4.0.2/lib/ruby/gems/4.0.0/gems/turbo-rails-2.0.23/app/assets/javascripts/turbo.js:5108-5156` — `StreamActions` definitions.
- `/Users/pawel/.frum/versions/4.0.2/lib/ruby/gems/4.0.0/gems/turbo-rails-2.0.23/app/assets/javascripts/turbo.js:5161-5260` — `<turbo-stream>` custom-element lifecycle, `turbo:before-stream-render` event payload.
- `/Users/pawel/.frum/versions/4.0.2/lib/ruby/gems/4.0.0/gems/turbo-rails-2.0.23/app/assets/javascripts/turbo.js:1642-1656` — `<turbo-frame>` autoscroll path (frame-only).
- [Turbo Streams handbook](https://turbo.hotwired.dev/handbook/streams)
- [Turbo Frames reference](https://turbo.hotwired.dev/reference/frames)
- [WHATWG HTML — autofocus attribute](https://html.spec.whatwg.org/multipage/interaction.html#the-autofocus-attribute)
- [Hotwire Discuss — autofocus an input after loading via stream](https://discuss.hotwired.dev/t/autofocus-an-input-after-loading-via-stream/3020)
- [MDN — overflow-anchor](https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-anchor) · [MDN — Guide to scroll anchoring](https://developer.mozilla.org/en-US/docs/Web/CSS/overflow-anchor/Guide_to_scroll_anchoring)
- [caniuse — overflow-anchor](https://caniuse.com/css-overflow-anchor) · [caniuse — scrollIntoView](https://caniuse.com/scrollintoview) · [caniuse — field-sizing:content](https://caniuse.com/mdn-css_properties_field-sizing_content)
- [Safari Technology Preview 238 release notes (Feb 26, 2026)](https://webkit.org/blog/17848/release-notes-for-safari-technology-preview-238/) · [WebKit bug 171099 (overflow-anchor)](https://bugs.webkit.org/show_bug.cgi?id=171099) · [WebKit bug 297779 (iOS 26 visualViewport regression)](https://bugs.webkit.org/show_bug.cgi?id=297779)
- [MDN — Element.scrollIntoView()](https://developer.mozilla.org/en-US/docs/Web/API/Element/scrollIntoView) · [mdn/browser-compat-data #22889](https://github.com/mdn/browser-compat-data/issues/22889)
- [MDN — field-sizing](https://developer.mozilla.org/en-US/docs/Web/CSS/field-sizing)
- [MDN — VisualViewport](https://developer.mozilla.org/en-US/docs/Web/API/VisualViewport) · [Fix mobile keyboard overlap with visualViewport](https://www.franciscomoretti.com/blog/fix-mobile-keyboard-overlap-with-visualviewport) · [bram.us — VirtualKeyboard API](https://www.bram.us/2021/09/13/prevent-items-from-being-hidden-underneath-the-virtual-keyboard-by-means-of-the-virtualkeyboard-api/)
