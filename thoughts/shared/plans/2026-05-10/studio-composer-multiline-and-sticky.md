---
date: 2026-05-10
author: Paweł Strzałkowski
status: ready
plan_for: studio composer — multiline textarea + sticky dock + scroll-to-bottom + auto-follow + ⌘/Ctrl+Enter + refocus
research: ./thoughts/shared/research/2026-05-09/studio-composer-multiline-and-sticky.md
---

# Studio composer — multiline + sticky + scroll-to-bottom Implementation Plan

## Overview

Turn the Build-tab prompt into a 2-row textarea that grows up to 5 rows, anchor the composer to the viewport bottom while the conversation scrolls, and add a horizontally-centered "scroll to bottom" affordance above the composer. While the area is open, also: auto-follow new bubbles when the user is already at bottom, refocus the input after Send (it currently loses focus on Turbo stream form-replace — research §F5), and accept ⌘/Ctrl+Enter as the submit shortcut now that Enter inserts a newline.

## Current State Analysis

- `app/views/messages/_form.html.erb:1-9` — single-line `<input type="text">` (`f.text_field`) inside a `.composer` flex card; `align-items: stretch` would make a textarea Send-button stretch.
- `app/views/projects/show.html.erb:1-60` — `#messages` and the form are siblings inside `#pane_build`. Body is the scroller. No `overflow`/`max-height`/`position: sticky` anywhere except `.app-nav`.
- `app/javascript/controllers/` — `tabs_controller.js`, `suggestions_controller.js`, `dismiss_controller.js`, `hello_controller.js`. No scroll-watcher; no MutationObserver/IntersectionObserver.
- `app/controllers/messages_controller.rb:9,19` — both responses are `turbo_stream.replace` of `dom_id(@project, :message_form)`. The replacement re-renders `_form.html.erb`. `autofocus` does **not** re-fire on Turbo stream replace (research §F5), so the cursor leaves the composer after every Send today.
- `app/models/message.rb:5-24` — `after_create_commit :broadcast_append_message` does the actual `append` to `target: "messages"`. `app/views/projects/show.html.erb:2` subscribes via `<%= turbo_stream_from @project %>`. Turbo's `append` action (research §F1) is `removeDuplicateTargetChildren` + `Element.append` — no scroll side-effects.
- `app/assets/tailwind/application.css:191` — `.app-shell { min-height: 100vh }` is the only viewport unit; no `dvh`/`svh`/`lvh` anywhere. Default Rails viewport meta (`app/views/layouts/application.html.erb:5`).

## Desired End State

- Composer is a 2-row textarea that grows linearly with newlines up to 5 rows, then internally scrolls.
- Composer card sits pinned to the viewport bottom while scrolling the Build conversation; respects iOS soft keyboard via `dvh`.
- A chevron-down button is stacked above the composer, horizontally centered, visible only when an end-of-`#messages` sentinel is **not** intersecting the viewport. Click → smooth scroll to that sentinel.
- When a new message is appended (or assistant chunks arrive) and the user was already at bottom, the page auto-scrolls so the latest content stays visible. If the user has scrolled up, their position is preserved.
- After Send, the cursor returns to the (now empty) composer.
- ⌘/Ctrl+Enter submits the form. Enter inserts a newline.

### Verification at the end

- All existing controller/integration tests still green: `bin/rails test`.
- New `messages_controller_test` case: a POST whose `content` contains a literal `\n` round-trips with the newline preserved into the persisted `Message#content`.
- Manual: after Send the composer is empty and focused. Typing 5 newlines grows the textarea to 5 rows; a 6th does not grow further but scrolls inside the textarea. ⌘/Ctrl+Enter sends. Composer stays pinned to the viewport bottom while scrolling. Down-arrow appears when scrolled up, hides when at bottom, smoothly returns the page to bottom on click. New messages auto-follow only when at bottom.

### Key Discoveries

- Sticky-bottom on the composer wrapper inside `#pane_build` is sufficient — no scroll-container surgery needed because no ancestor sets `overflow` other than visible (research §"Conversation scroll model").
- IntersectionObserver against a sentinel after `#messages` gives both signals at once: button visibility AND auto-follow gate.
- Turbo's `append` action does no scrolling (research §F1) — autoscroll lives only on `<turbo-frame>` (research §F2). Auto-follow must come from our side, off a MutationObserver on `#messages`.
- `field-sizing: content` is not in scope (research §F6 — Firefox unsupported May 2026); JS `rows`-clamp on `input` gives exact "grow on newline" semantics.

## What We're NOT Doing

- Not converting `#pane_build` (or `#messages`) into its own scroll container. Body stays the scroller.
- Not auto-scrolling on tab switch from Preview/Export → Build. User lands wherever they last left Build (we only auto-follow on broadcasts when already at bottom).
- Not changing the Send button to vertical-stacked layout. Bottom-anchored sibling is enough for now.
- Not touching `#projects/new`'s `f.text_area :description` — that's a different surface.
- Not addressing the `interactive-widget=resizes-content` viewport meta tweak (Android Chrome) — `dvh` covers iOS; Android Chrome's default behavior is acceptable.
- Not adding `overflow-anchor` rules — research §F3 confirms append-below-viewport doesn't need it.
- Not auto-growing for soft-wrapped lines. The `rows` clamp counts `\n` characters only — a long single line that visually wraps to 3+ rows still leaves the textarea at 2 rows, with later wrapped lines hidden until the user scrolls inside the textarea or inserts a newline. Acceptable tradeoff vs. the JS cost of measuring `scrollHeight` per keystroke (research §F6); revisit if `field-sizing: content` ships in Firefox stable.

## Implementation Approach

Five atomic phases. 1–3 are static (markup + CSS). 4 introduces the chat-scroll Stimulus controller. 5 extends it. Each phase ends in a working state — none of them require a follow-up to be correct.

---

## Phase 1: Multiline textarea + bottom-anchored Send

### Commit
`design: multiline composer textarea (2→5 rows) and bottom-anchor Send`

### Overview
Static markup/CSS-only swap from `<input type="text">` to `<textarea rows="2">` inside `.composer`. Re-align the Send button so it doesn't stretch to the textarea height.

### Changes Required

#### 1. `app/views/messages/_form.html.erb`
Replace the single-line input with a 2-row textarea. Keep the same `id`, `name`, placeholder, and `field-input` class so existing typography/colour rules apply unchanged.

```erb
<%= form_with url: project_messages_path(project), id: dom_id(project, :message_form), class: "composer" do |f| %>
  <%= f.text_area :content,
      id: "message_content_input",
      name: "message[content]",
      rows: 2,
      placeholder: "Continue the conversation…",
      class: "field-input",
      autofocus: true %>
  <%= f.submit "Send", class: "btn btn--primary" %>
<% end %>
```

Note: no `.field-textarea` class is added — its global rule (`resize: vertical; min-height: 96px` at `application.css:427`) is class-based, so `f.text_area` picks it up only when explicitly classed. Using only `.field-input` means the textarea inherits typography/border/padding from the global `.field-input, .field-textarea` block but stays free of the textarea-specific resize/min-height defaults intended for `/projects/new`.

#### 2. `app/assets/tailwind/application.css`
Two surgical changes in the COMPOSER section (lines 638–664):

```css
.composer {
  display: flex;
  gap: 8px;
  align-items: flex-end;          /* was: stretch */
  background: var(--paper-0);
  border: 1px solid var(--border-strong);
  border-radius: var(--radius-md);
  padding: 6px;
  transition: border-color var(--dur-fast) var(--ease-standard),
              box-shadow var(--dur-fast) var(--ease-standard);
}
/* …focus-within unchanged… */
.composer .field-input {
  flex: 1;
  background: transparent;
  border: 0;
  padding: 8px 10px;
  resize: none;                    /* NEW — textarea-specific; harmless on inputs */
}
/* :focus rule unchanged */
```

Only two new lines vs. today: `align-items: flex-end` on `.composer`, and `resize: none` on `.composer .field-input`. Font / line-height / color all flow through from the global `.field-input` rule unchanged.

### Success Criteria

#### Automated Verification
- [x] All existing tests pass: `bin/rails test`
- [x] Specifically `bin/rails test test/controllers/messages_controller_test.rb` — confirms the form name (`message[content]`) hasn't changed and the controller still works.
- [x] Add a new test: `POST` with `content: "line one\nline two"` persists the message with the newline intact (`assert_equal "line one\nline two", message.content`).

#### Manual Verification
- [ ] Composer renders as a 2-row textarea. Typing newlines does not yet auto-grow (Phase 2).
- [ ] Send button sits at the bottom-right of the composer card and is the same height as before (does not stretch).
- [ ] Submitting still works; the message appears in the conversation; the form re-renders empty.
- [ ] No regressions on `/projects/new` — the suggestions textarea still behaves and looks correct.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: Composer Stimulus controller (refocus + auto-grow + ⌘/Ctrl+Enter)

### Commit
`design: composer controller — refocus, auto-grow rows 2→5, ⌘/Ctrl+Enter submit`

### Overview
A single small controller that owns three behaviors on the composer textarea: refocus on connect (so post-Send re-render restores the cursor), `rows` clamp on `input`, and submit-on-modifier-enter on `keydown`. All three behaviors live on the same element and mutate the same target — bundling avoids three trivially-coupled commits.

### Changes Required

#### 1. `app/javascript/controllers/composer_controller.js` (new file)

```javascript
import { Controller } from "@hotwired/stimulus"

// Composer behaviors:
//   - connect():     focus the textarea (restores cursor after Turbo stream form-replace,
//                    since the HTML autofocus attribute does not re-fire on stream replace)
//   - resize():      on input, set rows = clamp(min, newline-count, max)
//   - submit():      on keydown, ⌘/Ctrl+Enter requestSubmit()s the form
export default class extends Controller {
  static targets = ["input"]
  static values  = { minRows: { type: Number, default: 2 },
                     maxRows: { type: Number, default: 5 } }

  connect() {
    if (this.hasInputTarget) this.inputTarget.focus()
    this.resize()
  }

  resize() {
    if (!this.hasInputTarget) return
    const lines = this.inputTarget.value.split("\n").length
    const clamped = Math.max(this.minRowsValue, Math.min(this.maxRowsValue, lines))
    this.inputTarget.rows = clamped
  }

  submit(event) {
    if (event.key !== "Enter") return
    if (!(event.metaKey || event.ctrlKey)) return
    // Ignore Enter while an IME is composing (CJK input, some dead-key layouts):
    // the keypress is "commit composition", not "submit". keyCode 229 is the
    // legacy fallback for browsers that don't expose isComposing on the event.
    if (event.isComposing || event.keyCode === 229) return
    event.preventDefault()
    this.element.requestSubmit()
  }
}
```

#### 2. `app/views/messages/_form.html.erb` — wire the controller

```erb
<%= form_with url: project_messages_path(project),
              id: dom_id(project, :message_form),
              class: "composer",
              data: { controller: "composer",
                      composer_min_rows_value: 2,
                      composer_max_rows_value: 5 } do |f| %>
  <%= f.text_area :content,
      id: "message_content_input",
      name: "message[content]",
      rows: 2,
      placeholder: "Continue the conversation…",
      class: "field-input",
      data: { composer_target: "input",
              action: "input->composer#resize keydown->composer#submit" } %>
  <%= f.submit "Send", class: "btn btn--primary" %>
<% end %>
```

`autofocus: true` is removed from the textarea — the Stimulus controller now owns focus (it works correctly across both initial page load and post-Send re-render, which `autofocus` does not — research §F5).

### Success Criteria

#### Automated Verification
- [x] All tests still green: `bin/rails test`.

#### Manual Verification
- [ ] On `/projects/:id` page load, the composer is focused (cursor is in the textarea).
- [ ] Typing a newline grows the textarea by one row, up to 5; the 6th newline does not grow further (textarea scrolls internally).
- [ ] Deleting newlines shrinks the textarea, never below 2 rows.
- [ ] Pressing Enter inserts a newline (does not submit).
- [ ] Pressing ⌘+Enter (mac) or Ctrl+Enter (linux/windows) submits the form.
- [ ] After Send, the form is replaced and the cursor lands back in the empty composer.
- [ ] No console errors.

**Implementation Note**: pause for manual confirmation before Phase 3.

---

## Phase 3: Sticky composer dock

### Commit
`design: sticky composer dock pinned to viewport bottom`

### Overview
Wrap the composer in a `.composer-dock` and make that wrapper `position: sticky; bottom: 0` inside `#pane_build`. Switch `.app-shell { min-height: 100vh }` → `100dvh` so the dock rides correctly above the iOS soft keyboard (research §F7). Pure layout — no JS.

### Changes Required

#### 1. `app/views/projects/show.html.erb` — wrap composer in dock

```erb
<div id="pane_build"
     role="tabpanel"
     aria-labelledby="tab_build"
     tabindex="0"
     data-tabs-target="pane"
     data-tab-name="build">
  <div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">
    <% @chat_events.each do |event| %>
      …
    <% end %>
  </div>
  <div class="composer-dock">
    <%= render "messages/form", project: @project %>
  </div>
</div>
```

The previous `<div style="margin-top: 16px;">` wrapper around the form is replaced by `.composer-dock`, which owns its own spacing in CSS.

#### 2. `app/assets/tailwind/application.css`

a. Bump `.app-shell` (line 190–195) to use `dvh`, with a `vh` fallback for browsers without `dvh` support (Safari < 15.4, Chrome < 108, Firefox < 101 — pre-mid-2022; without the fallback, those browsers reject the unknown `dvh` token and `.app-shell` loses its min-height entirely):

```css
.app-shell {
  min-height: 100vh;             /* fallback for browsers without dvh support */
  min-height: 100dvh;            /* tracks visual viewport — handles iOS soft keyboard */
  background: var(--bg);
  display: flex;
  flex-direction: column;
}
```

b. Add a new `.composer-dock` rule, immediately above the existing `.composer` block in the COMPOSER section:

```css
.composer-dock {
  position: sticky;
  bottom: 0;
  z-index: 10;                   /* below the sticky nav (z-index: 30) */
  background: var(--bg);
  padding-top: 12px;
  padding-bottom: 16px;
  margin-top: 16px;              /* replaces the old inline margin-top: 16px */
}
```

Background colour ensures messages scrolling under the dock don't bleed through when the dock is sticky-pinned and a wide message would otherwise show through the gap above the composer card.

c. **Breathing room above the sticky dock — deferred to Phase 4.** An earlier draft put `scroll-padding-bottom: 140px` on `#pane_build`, but `scroll-padding-*` only takes effect on a *scroll container* (an element whose computed `overflow` is non-`visible`), and `#pane_build` is not one — the body is the scroller. The correct attachment point is on the **scroll target itself** via `scroll-margin-bottom`, which travels with the element regardless of which ancestor scrolls. Since the scroll target (the `#messages_end` sentinel) doesn't exist until Phase 4, the rule lives there.

### Success Criteria

#### Automated Verification
- [x] All tests still green: `bin/rails test`.
- [x] No CSS lint regressions if a linter is configured (none today).

#### Manual Verification
- [ ] Composer card stays pinned to the viewport bottom while scrolling the Build conversation up/down.
- [ ] Scrolling all the way to the very top of the page (eyebrow + h1 + tab nav visible) — composer remains at viewport bottom; nothing overlaps the sticky nav.
- [ ] Switch to Preview tab → composer disappears (because `#pane_build` becomes `display: none`). Switch back → composer is sticky again. No layout flicker.
- [ ] On iOS Safari (or simulator), tap the textarea: the soft keyboard rises and the composer rides above the keyboard, not behind it.
- [ ] Last assistant bubble can be read in full (not occluded by the dock) when scrolling up just enough to push it above the dock.

**Implementation Note**: pause for manual confirmation before Phase 4.

---

## Phase 4: Scroll-to-bottom button + sentinel + IntersectionObserver

### Commit
`design: scroll-to-bottom button on studio composer dock`

### Overview
Introduce a sentinel `<div id="messages_end">` after `#messages`, a chevron-down button stacked above the composer in `.composer-dock`, and a new `chat_scroll_controller.js` whose IntersectionObserver toggles the button's visibility based on whether the sentinel is in the viewport. Click → smooth scroll to the sentinel.

### Changes Required

#### 1. `app/views/projects/show.html.erb` — add controller, sentinel, button

```erb
<div id="pane_build"
     role="tabpanel"
     aria-labelledby="tab_build"
     tabindex="0"
     data-tabs-target="pane"
     data-tab-name="build"
     data-controller="chat-scroll">
  <div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">
    <% @chat_events.each do |event| %>
      …
    <% end %>
  </div>
  <div id="messages_end" data-chat-scroll-target="sentinel" aria-hidden="true" class="messages-end"></div>
  <div class="composer-dock">
    <button type="button"
            class="composer-dock__jump"
            data-chat-scroll-target="jumpButton"
            data-action="click->chat-scroll#jumpToEnd"
            aria-label="Scroll to latest"
            hidden>
      <svg viewBox="0 0 16 16" width="20" height="20" aria-hidden="true">
        <path fill="none" stroke="currentColor" stroke-width="1.5"
              stroke-linecap="round" stroke-linejoin="round"
              d="M3 6l5 5 5-5"/>
      </svg>
    </button>
    <%= render "messages/form", project: @project %>
  </div>
</div>
```

The button uses the native `hidden` attribute as its initial state and the controller toggles it.

#### 2. `app/javascript/controllers/chat_scroll_controller.js` (new file)

```javascript
import { Controller } from "@hotwired/stimulus"

// Watches an end-of-conversation sentinel. While the sentinel is in the
// viewport, the conversation is at-bottom: hide the jump button. When the
// sentinel leaves the viewport (user scrolled up, or new content pushed it
// out of view), show the button. Click → smooth-scroll to the sentinel.
export default class extends Controller {
  static targets = ["sentinel", "jumpButton"]

  connect() {
    this.atBottom = false
    // rootMargin shrinks the IO viewport's bottom by 120px so the sentinel
    // counts as "out of view" once it slips behind the sticky composer dock,
    // not only when it leaves the literal viewport. 120px ≈ 2-row composer
    // (50) + button (36) + dock padding/margin (~30). Tune in lockstep with
    // the sentinel's scroll-margin-bottom below.
    this.observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        this.atBottom = entry.isIntersecting
        if (this.hasJumpButtonTarget) {
          this.jumpButtonTarget.hidden = entry.isIntersecting
        }
      }
    }, { root: null, threshold: 0, rootMargin: "0px 0px -120px 0px" })

    if (this.hasSentinelTarget) this.observer.observe(this.sentinelTarget)
  }

  disconnect() {
    if (this.observer) this.observer.disconnect()
  }

  jumpToEnd() {
    if (this.hasSentinelTarget) {
      this.sentinelTarget.scrollIntoView({ behavior: "smooth", block: "end" })
    }
  }
}
```

#### 3. `app/assets/tailwind/application.css` — extend dock rule + add button rules

**Important**: do NOT re-add `.composer-dock` as a new block. The rule already exists from Phase 3 §2(b). **Edit it in place** to add the four flex properties below (sticky/bg/padding/margin remain untouched). Then append the new `.messages-end` rule (the scroll-target breathing room that Phase 3 §2(c) deferred) and the `.composer-dock__jump` rules.

```css
/* MODIFY existing .composer-dock from Phase 3 — add only the four flex lines */
.composer-dock {
  position: sticky;
  bottom: 0;
  z-index: 10;
  background: var(--bg);
  padding-top: 12px;
  padding-bottom: 16px;
  margin-top: 16px;
  display: flex;                    /* NEW in Phase 4 — was implicit block */
  flex-direction: column;           /* NEW in Phase 4 */
  align-items: stretch;             /* NEW in Phase 4 */
  gap: 8px;                         /* NEW in Phase 4 */
}

/* NEW — sentinel breathing room above the sticky dock.
   `scroll-margin-bottom` outsets the scroll snap area on the target itself,
   so scrollIntoView({ block: 'end' }) leaves room for the dock without
   needing the body/html to be a scroll container with scroll-padding.
   Keep the value in sync with chat_scroll_controller.js's IO rootMargin. */
.messages-end { scroll-margin-bottom: 140px; }

/* NEW — append below the dock rule */
.composer-dock__jump {
  align-self: center;               /* horizontally centered above composer */
  appearance: none;
  background: var(--paper-0);
  color: var(--fg);
  border: 1px solid var(--border-strong);
  border-radius: 999px;
  width: 36px;
  height: 36px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  transition: background-color var(--dur-fast) var(--ease-standard),
              border-color var(--dur-fast) var(--ease-standard);
}
.composer-dock__jump:hover {
  background: var(--paper-50);
  border-color: var(--accent);
}
.composer-dock__jump:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
/* native [hidden] disables flex layout — button cleanly drops out of layout */
```

### Success Criteria

#### Automated Verification
- [x] All tests still green: `bin/rails test`.

#### Manual Verification
- [ ] On a project with enough messages to overflow the viewport: scroll up → chevron-down button appears above the composer, horizontally centered. Scroll back to bottom → button disappears.
- [ ] Click the button → page smoothly scrolls down so the last message is visible above the dock.
- [ ] Button has a focus ring on Tab focus and is reachable by keyboard.
- [ ] On a project with few messages (no overflow): button never appears (sentinel stays in view).
- [ ] No console errors. Switching tabs doesn't break the observer (sentinel inside `display: none` parent → not intersecting → button shows but is hidden by `display: none`; switching back → sentinel intersects again → button hides).

**Implementation Note**: pause for manual confirmation before Phase 5.

---

## Phase 5: Auto-follow on broadcast

### Commit
`design: auto-follow studio conversation when at bottom on broadcast`

### Overview
Extend `chat_scroll_controller.js` with a MutationObserver on `#messages`. When new bubbles or chunks arrive and the controller's `atBottom` flag is true, instant-scroll to the sentinel. Behaviour is `auto` (not `smooth`) so streaming chunks don't kick off continuous animations. Scroll calls are coalesced into one per animation frame via `requestAnimationFrame` so a burst of mutations (each streaming chunk replaces the assistant partial via `broadcast_replace_message`, and rapid chunks can fire many mutations per second) doesn't trigger one `scrollIntoView` call per mutation. No new files; no new markup.

### Changes Required

#### 1. `app/javascript/controllers/chat_scroll_controller.js` — extend

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["sentinel", "jumpButton"]

  connect() {
    // Start false: the IO callback fires asynchronously after observe(), so
    // there is a brief window between connect() and the first callback. A
    // broadcast arriving in that window with atBottom = true would auto-scroll
    // a user who didn't intend to follow (e.g. landing mid-stream on a long
    // chat). Defaulting false errs on the side of "do nothing" — the IO will
    // flip it true within ~16ms if the sentinel is genuinely in view.
    this.atBottom = false
    this.messagesElement = this.element.querySelector("#messages")
    this.followFrame = null

    // rootMargin: see Phase 4 — shrinks IO viewport's bottom by 120px so the
    // sentinel registers as "out of view" once it slips behind the sticky
    // composer dock. Keep in sync with .messages-end's scroll-margin-bottom.
    this.intersectionObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        this.atBottom = entry.isIntersecting
        if (this.hasJumpButtonTarget) {
          this.jumpButtonTarget.hidden = entry.isIntersecting
        }
      }
    }, { root: null, threshold: 0, rootMargin: "0px 0px -120px 0px" })
    if (this.hasSentinelTarget) this.intersectionObserver.observe(this.sentinelTarget)

    if (this.messagesElement) {
      this.mutationObserver = new MutationObserver(() => this.scheduleFollow())
      // childList only — broadcasts append/replace whole message partials.
      // characterData would fire on every text-node mutation inside an
      // existing partial; broadcast_replace_message swaps the partial wholesale,
      // so characterData adds noise (and cost during streaming) without signal.
      this.mutationObserver.observe(this.messagesElement, {
        childList: true,
        subtree: true,
      })
    }
  }

  disconnect() {
    if (this.intersectionObserver) this.intersectionObserver.disconnect()
    if (this.mutationObserver) this.mutationObserver.disconnect()
    if (this.followFrame) cancelAnimationFrame(this.followFrame)
  }

  jumpToEnd() {
    if (this.hasSentinelTarget) {
      this.sentinelTarget.scrollIntoView({ behavior: "smooth", block: "end" })
    }
  }

  // Coalesce a burst of mutations (e.g. several streaming chunks landing in
  // the same frame) into a single scrollIntoView call.
  scheduleFollow() {
    if (this.followFrame) return
    this.followFrame = requestAnimationFrame(() => {
      this.followFrame = null
      this.followIfAtBottom()
    })
  }

  followIfAtBottom() {
    if (!this.atBottom) return
    if (!this.hasSentinelTarget) return
    this.sentinelTarget.scrollIntoView({ behavior: "auto", block: "end" })
  }
}
```

### Success Criteria

#### Automated Verification
- [x] All tests still green: `bin/rails test`.

#### Manual Verification
- [ ] Send a message while scrolled to bottom → user bubble appears, page stays pinned to bottom (the new bubble is visible above the dock).
- [ ] Watch an assistant message stream in chunks while at bottom → page tracks the growing bubble, last line stays visible just above the dock.
- [ ] Scroll up so the chevron-down button appears, then send a new message → page does **not** auto-scroll. The button shows (sentinel out of view) and remains until clicked or until the user scrolls down.
- [ ] After clicking the down-arrow to jump back to bottom, subsequent broadcasts auto-follow again.
- [ ] No "scroll fight" — auto-follow uses `behavior: 'auto'` so streaming chunks don't spawn overlapping smooth animations.
- [ ] Open Preview tab while assistant is streaming → no errors. Return to Build tab → user lands at last scroll position; auto-follow resumes only if at bottom.

**Implementation Note**: pause for manual confirmation; this is the last phase.

---

## Testing Strategy

### New automated test
- `test/controllers/messages_controller_test.rb` — add a single case for multiline content survival:
  ```ruby
  test "POST with multiline content preserves newlines" do
    post project_messages_path(@project), params: { message: { content: "line one\nline two" } }
    assert_equal "line one\nline two", @project.chat.messages.order(:created_at).last.content
  end
  ```
  This is the only new branch the input → textarea swap introduces at the controller boundary. Per [feedback_test_branch_coverage]: one test per logical branch.

### Existing automated tests
The full `bin/rails test` suite must still pass through every phase. No existing test should require modification (the form name and HTTP contract are unchanged).

### Manual testing
Each phase has its own manual checklist above. Do not skip the per-phase pause: visible regressions in sticky/dvh/observer behavior are not caught by Minitest.

JavaScript controllers are not unit-tested — the repo has no JS test framework. Behavior is verified manually.

## Performance Considerations

- IntersectionObserver and MutationObserver are passive and used in chat UIs at scale; per-page cost is negligible.
- The MutationObserver watches `childList + subtree` (no `characterData` — broadcasts swap whole partials, not text nodes). A burst of mutations in the same frame is coalesced into one `scrollIntoView` via `requestAnimationFrame`, so streaming-chunk rate doesn't translate 1:1 to scroll-call rate.
- `scroll-margin-bottom: 140px` lives on `.messages-end` — the only DOM element with that class is the studio's sentinel, so the rule has no spillover to other surfaces and no runtime cost. The IO `rootMargin` (-120px on the bottom) and the sentinel's `scroll-margin-bottom` (140px) are deliberately tied: the rootMargin defines "where the dock visually starts occluding" for the *button-visibility* signal; the scroll-margin defines "where the dock starts occluding" for the *scroll-target* offset. Same concept, applied to the two complementary primitives.

## Migration Notes

None — purely additive frontend changes. No DB migration, no data backfill. Existing per-project channels and broadcasts are unchanged.

## References

- Research: `./thoughts/shared/research/2026-05-09/studio-composer-multiline-and-sticky.md`
- `app/views/messages/_form.html.erb:1-9` — current single-line composer
- `app/views/projects/show.html.erb:14-33` — `#pane_build` containing `#messages` + composer wrapper
- `app/javascript/controllers/tabs_controller.js` — Stimulus pattern reference
- `app/controllers/messages_controller.rb:9,19` — Turbo stream form-replace responses
- `app/models/message.rb:5-24` — `broadcast_append_message` to `target: "messages"`
- `app/assets/tailwind/application.css:190-204` — `.app-shell` + sticky `.app-nav`
- `app/assets/tailwind/application.css:399-421` — `.field-input` / `.field-textarea` rules
- `app/assets/tailwind/application.css:638-664` — current `.composer` rules (post surface-lift commit `349e557`)
- Research §F1 — Turbo Stream `append` mechanics (no scroll involvement)
- Research §F3 — overflow-anchor matrix (append-below-viewport doesn't need it)
- Research §F5 — `autofocus` does not re-fire on Turbo stream replace
- Research §F6 — auto-grow techniques (`field-sizing: content` vs JS `rows` clamp)
- Research §F7 — `dvh` + iOS soft keyboard
