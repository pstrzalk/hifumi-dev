---
date: 2026-05-08
author: Paweł Strzałkowski
status: ready-for-implementation
research: thoughts/shared/research/2026-05-08/authenticated-screens-layout-and-project-show-tabs.md
---

# Studio tabs (Hi · Build / Fu · Preview / Mi · Export) + 1600-px shell — Implementation Plan

## Overview

Replace the project-show two-column grid with a three-tab studio (Build / Preview / Export) and widen the authenticated app shell from 1120 px to 1600 px. All three panes stay mounted in the DOM at all times (only `display:none` toggles between them) so the existing single-channel Turbo Stream subscription (`turbo_stream_from @project`) keeps landing every broadcast on its current target id, regardless of which tab is showing.

## Current State Analysis

- The studio at `app/views/projects/show.html.erb:1-46` is a single `<section style="max-width: 1120px">` containing one CSS grid (`grid lg:grid-cols-2 gap-6` at line 11). Left column = Build (revisions + messages + composer); right column = Preview pane stacked above GitHub Export pane in `lg:sticky lg:top-4 lg:h-fit` at line 39.
- The `1120px` figure lives in **four uncoupled places**: `.app-nav-inner` at `app/assets/tailwind/application.css:198`, the `:notice` flash strip inline at `app/views/layouts/application.html.erb:44`, the `:alert` flash strip inline at `:52`, and the studio section inline at `app/views/projects/show.html.erb:1`. No shared variable.
- A second `flash[:alert]` strip is duplicated inside the Build column at `app/views/projects/show.html.erb:26-33`. The page-level layout strip at `app/views/layouts/application.html.erb:51-57` already covers `:alert` for every page.
- Every broadcast on the show page passes through one Action Cable subscription (`turbo_stream_from @project` at `show.html.erb:2`) and targets plain DOM ids: `#chat_notice`, `#active_revisions`, `#messages`, `#message_<id>`, `#revision_<id>`, `#preview`, `#github_export_pane`, `#project_<id>_message_form`. All target ids must remain in the document for hidden tabs to keep absorbing updates.
- Per-page widths today: studio 1120, projects index/new 720, Devise 420/480, marketing 1280. The 720/420/480/1280 pages are out of scope for this plan.
- Existing Stimulus controllers (`app/javascript/controllers/dismiss_controller.js`, `suggestions_controller.js`) use the param-based pattern `data-<controller>-<value>-param`; eager-loaded via `app/javascript/controllers/index.js`, no manual registration step.
- The hifumi composition for the kanji + mono-eyebrow + numeral pattern already exists on the marketing home (`app/views/home/index.html.erb:18-49`, classes `.pipeline-step`, `.pipeline-step__numeral`, `.pipeline-step__label`, defined at `app/assets/tailwind/application.css:687-735`). The tab strip reuses these primitives — kanji glyph (`一 二 三`) in Source Serif 4, mono-caps label, accent on the active tab.

## Desired End State

On `GET /projects/:id`:

1. The studio outer `<section>` is `max-width: 1600px`. The top-nav inner container and the two layout-level flash strips are also 1600 px (alignment with the studio content area).
2. Below the page header (`studio · project_<id>` eyebrow + `<h1>`) and the `#chat_notice` row, a tab strip shows three buttons: **Hi · 01 · Build** (default active, kanji 一), **Fu · 02 · Preview** (kanji 二), **Mi · 03 · Export** (kanji 三). Active tab: kanji and label in `--accent`/`--ink-800`, 2-px accent underline. Inactive: muted, no underline.
3. Three pane `<div>`s are present in the DOM at all times. Two are hidden via inline `style="display: none"`. Clicking a tab toggles the active class on the buttons and the `display` style on the panes — no network request, no URL change. The tab strip implements the full WAI-ARIA tabs pattern: `role="tablist"` / `role="tab"` / `role="tabpanel"`, `aria-selected`, `aria-controls` on tabs, `aria-labelledby` on panels, roving `tabindex` (active=0, inactive=-1), and Left/Right/Home/End arrow-key navigation through the tab buttons.
4. Build pane = chat messages feed (`#messages`) + composer form (`#project_<id>_message_form`). The page-level `#chat_notice` sits between header and tab strip — *not* inside Build — so an LLM error is visible regardless of active tab.
5. Preview pane = `#active_revisions` on top (relocated from the old Build column) + existing `previews/_pane` (which renders `#preview` and the iframe) below.
6. Export pane = existing `github_exports/_pane` (turbo frame `github_export_pane`) as-is.
7. The duplicated inline `flash[:alert]` strip at `show.html.erb:26-33` is removed; the layout-level alert at `application.html.erb:51-57` is the single source.
8. While the user is on Preview or Export, broadcasts targeting `#messages`, `#message_<id>`, `#chat_notice`, etc. continue to land — the targets are present in the DOM, just hidden. Switching back to Build shows the up-to-date state immediately.

Verifiable by:
- `bundle exec rails test test/controllers/projects_controller_show_test.rb` — green, with new branch coverage for the tab DOM structure.
- `bundle exec rails test` — full suite green, no regressions.
- Manual click-through (Phase 1 + Phase 2 manual gates below).

### Key Discoveries

- `app/views/projects/show.html.erb:2` — single `turbo_stream_from @project` subscription is the entire page's broadcast surface; no per-section subscription.
- `config/initializers/event_subscribers.rb:13-18,50-55,109-114` broadcast revision/instruction updates to `target: "active_revisions"`. Moving the `#active_revisions` div into the Preview tab does **not** require any subscriber change as long as the id is still present in the DOM.
- `app/jobs/chat_respond_job.rb:62-69` broadcasts to `target: "chat_notice"`. Keeping `#chat_notice` page-level (above the tab strip) keeps that broadcast working without change.
- `app/views/previews/_pane.html.erb:1` is `<div id="preview" class="preview-pane">`; `lib/preview/preview_manager.rb:325-332` broadcasts replace to `target: "preview"`. Untouched.
- `app/views/github_exports/_pane.html.erb:1` is `<%= turbo_frame_tag "github_export_pane" %>`; `app/jobs/export_to_github_job.rb:108-115` broadcasts replace to `target: "github_export_pane"`. Untouched.
- `app/javascript/controllers/index.js` eager-loads `controllers/**/*_controller.js` via `eagerLoadControllersFrom("controllers", application)` — adding `tabs_controller.js` requires no manual register call.
- `app/assets/tailwind/application.css:153-172` defines `.eyebrow`, `.numeral`, `.kanji` — the typographic primitives the tab labels reuse.
- `app/assets/tailwind/application.css:710-722` defines `.pipeline-step__numeral` (Source Serif 4, 56 px, accent on active) and `.pipeline-step__label` (mono caps, 11 px, --fg-muted) — the size/weight reference for the tab labels (sized down for tab chrome).
- `app/assets/tailwind/application.css:395-402` — `.tag-dot` and the `hi-blink` keyframe; **not used** in this plan (decision: no live dots on tabs) but cited for reference.

## What We're NOT Doing

- **No URL hash, no localStorage, no routing.** Tab choice resets to Build on every page load. Refresh = back to Build.
- **No live status dot on the tab labels.** Per-tab live indication is out — the panes already show their own status pills.
- **No lazy loading of pane content.** All three panes render server-side on every `show`. Hiding is purely visual.
- **No width changes to other pages.** Devise (420/480), projects index/new (720), home/marketing (1280) stay as-is. Narrow forms not centering to studio center is acceptable.
- **No new container width token.** The four 1600-px occurrences stay independent — same convention as the four 1120-px occurrences they replace. (Centralizing is a separate refactor; not in scope.)
- **No system test (Capybara/Selenium).** Per the `project_verify_no_system_tests` convention and the absence of `test/system/` in this repo, the toggle is verified by controller-level `assert_select` (initial DOM structure) plus the manual gate (clicking through tabs).
- **No changes to `instruction.requested` → `StopPreviewJob` wiring** or any other broadcast subscriber. The contract with broadcasts is "every target id is present in the DOM"; tabs preserve that.
- **No tab-strip-level error or empty states.** A project with zero instructions still shows all three tabs; Preview just shows its existing `_stopped` partial and an empty `#active_revisions` slot.

## Implementation Approach

Two atomic commits. Phase 1 is a width-only swap with no behavior change — independently revertable, immediately visible in the browser. Phase 2 is the tab refactor: tab nav partial + Stimulus controller + CSS + `show.html.erb` rewrite + controller-level test, all coupled and shipped together.

---

## Phase 1: Bump shell width 1120 → 1600 px

### Commit
`studio: widen authenticated shell to 1600px`

### Overview
Four edits in three files. No behavior change. Lands first so Phase 2 reviewers see the tab-strip mockup at the new width and the layout chrome (nav, flashes) is already aligned with studio content.

### Changes Required

#### 1. Top-nav inner container

**File**: `app/assets/tailwind/application.css`
**Change**: line 198, `max-width: 1120px;` → `max-width: 1600px;`

```css
.app-nav-inner {
  max-width: 1600px;   /* was 1120px */
  margin: 0 auto;
  height: 100%;
  /* …rest unchanged… */
}
```

#### 2. Layout flash strips

**File**: `app/views/layouts/application.html.erb`
**Change**: lines 44 and 52, both inline `style="max-width: 1120px; margin: 0 auto 16px;"` → `style="max-width: 1600px; margin: 0 auto 16px;"`

```erb
<div class="notice-strip notice-strip--ok" style="max-width: 1600px; margin: 0 auto 16px;">
…
<div class="notice-strip notice-strip--err" style="max-width: 1600px; margin: 0 auto 16px;">
```

#### 3. Studio outer section

**File**: `app/views/projects/show.html.erb`
**Change**: line 1, `style="max-width: 1120px; margin: 0 auto;"` → `style="max-width: 1600px; margin: 0 auto;"`

```erb
<section style="max-width: 1600px; margin: 0 auto;">
```

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test` green.
- [ ] `git grep -n "1120" -- '*.css' '*.html.erb'` returns zero hits inside `app/views/layouts/application.html.erb`, `app/views/projects/show.html.erb`, and `app/assets/tailwind/application.css`. (Other repos / docs / thoughts mentions don't matter — they're history.)
- [ ] `git grep -n "1600" app/views/layouts/application.html.erb app/views/projects/show.html.erb app/assets/tailwind/application.css` returns exactly four hits (one in each .erb, one in the CSS — note both flash strips are in the same .erb).

#### Manual:
- [ ] `bin/dev` running, `GET /projects/<id>`: studio content stretches to 1600 px on a wide monitor; preview iframe still renders inside it without breaking.
- [ ] Top nav (`hifumi.dev · Projects · Account · Sign out`) aligns left-edge with studio content (both at the 1600-px container's left padding).
- [ ] Trigger a `:notice` flash (e.g. by signing out and back in): strip is centered at 1600 px, top edge below the nav.
- [ ] Trigger an `:alert` flash (e.g. submitting an empty `POST /projects`): strip aligns identically.
- [ ] `GET /projects` (index, 720 px) and `GET /users/edit` (Devise, 480 px) still render at their existing narrower widths — no regression on the other pages.

**Pause for manual confirmation before proceeding to Phase 2.**

---

## Phase 2: Studio tabs (Hi · Build / Fu · Preview / Mi · Export)

### Commit
`studio: tabs (Build / Preview / Export) replacing two-column grid`

### Overview
Replaces the `grid lg:grid-cols-2 gap-6` layout with a three-tab strip. Build pane = chat. Preview pane = revisions table on top of preview iframe. Export pane = GitHub export form. All three are always mounted; toggling is `display:none` only. The duplicated inline `flash[:alert]` strip in the old left column is removed (layout-level alert covers it).

### Changes Required

#### 1. Stimulus controller

**File**: `app/javascript/controllers/tabs_controller.js` (new)

```javascript
import { Controller } from "@hotwired/stimulus"

// Single-root tabs controller. Toggles `display: none` on pane elements
// and an `is-active` class on tab buttons. No URL state, no localStorage.
//
// Implements the WAI-ARIA tabs pattern
// (https://www.w3.org/WAI/ARIA/apg/patterns/tabs/):
//   - `aria-selected` and roving `tabindex` reflect the active tab
//   - Left/Right/Home/End arrow keys cycle focus through tab buttons
//   - panes carry role="tabpanel" + aria-labelledby (set in show.html.erb)
//
// Markup contract (see app/views/projects/_tab_nav.html.erb and
// app/views/projects/show.html.erb):
//
//   <div data-controller="tabs" data-tabs-active-value="build">
//     <button id="tab_build"   role="tab" aria-controls="pane_build"   tabindex="0"
//             data-tabs-target="tab" data-tab-name="build" …>…</button>
//     <button id="tab_preview" role="tab" aria-controls="pane_preview" tabindex="-1"
//             data-tabs-target="tab" data-tab-name="preview" …>…</button>
//     <button id="tab_export"  role="tab" aria-controls="pane_export"  tabindex="-1"
//             data-tabs-target="tab" data-tab-name="export" …>…</button>
//     <div id="pane_build"   role="tabpanel" aria-labelledby="tab_build"   tabindex="0"
//          data-tabs-target="pane" data-tab-name="build">…</div>
//     <div id="pane_preview" role="tabpanel" aria-labelledby="tab_preview" tabindex="0"
//          data-tabs-target="pane" data-tab-name="preview" style="display:none">…</div>
//     <div id="pane_export"  role="tabpanel" aria-labelledby="tab_export"  tabindex="0"
//          data-tabs-target="pane" data-tab-name="export"  style="display:none">…</div>
//   </div>
export default class extends Controller {
  static targets = ["tab", "pane"]
  static values = { active: { type: String, default: "build" } }

  connect() {
    this.render()
  }

  switch(event) {
    const name = event.currentTarget.dataset.tabName
    if (!name) return
    this.activeValue = name
    event.currentTarget.focus()
  }

  keydown(event) {
    const tabs = this.tabTargets
    const idx = tabs.indexOf(event.currentTarget)
    if (idx < 0) return

    let nextIdx = null
    switch (event.key) {
      case "ArrowLeft":  nextIdx = (idx - 1 + tabs.length) % tabs.length; break
      case "ArrowRight": nextIdx = (idx + 1) % tabs.length; break
      case "Home":       nextIdx = 0; break
      case "End":        nextIdx = tabs.length - 1; break
      default: return
    }
    event.preventDefault()
    const next = tabs[nextIdx]
    this.activeValue = next.dataset.tabName
    next.focus()
  }

  activeValueChanged() {
    this.render()
  }

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
}
```

No registration step needed: `app/javascript/controllers/index.js` eager-loads `controllers/**/*_controller.js`.

#### 2. Tab nav partial

**File**: `app/views/projects/_tab_nav.html.erb` (new)

```erb
<%#
  Studio tab strip. Renders three tab buttons (Build / Preview / Export).
  The Stimulus `tabs` controller (data-controller="tabs" on the parent)
  toggles which pane is visible. Default active = "build".

  Implements the full WAI-ARIA tabs pattern:
  - role="tablist" on container, role="tab" + aria-selected + aria-controls
    on each button, with roving tabindex (active=0, inactive=-1)
  - Arrow keys (Left/Right/Home/End) wired via data-action keydown→tabs#keydown
  - Panes live in show.html.erb and carry role="tabpanel" + aria-labelledby
%>
<nav class="tab-nav" role="tablist" aria-label="studio sections" aria-orientation="horizontal">
  <% [
    [:build,   "一", "hi · 01 · build"],
    [:preview, "二", "fu · 02 · preview"],
    [:export,  "三", "mi · 03 · export"]
  ].each do |name, glyph, label| %>
    <% active = (name == :build) %>
    <button type="button"
            id="tab_<%= name %>"
            class="tab-button<%= " is-active" if active %>"
            role="tab"
            aria-selected="<%= active ? "true" : "false" %>"
            aria-controls="pane_<%= name %>"
            tabindex="<%= active ? "0" : "-1" %>"
            data-tabs-target="tab"
            data-tab-name="<%= name %>"
            data-action="click->tabs#switch keydown->tabs#keydown">
      <span class="tab-button__numeral kanji" aria-hidden="true"><%= glyph %></span>
      <span class="tab-button__label"><%= label %></span>
    </button>
  <% end %>
</nav>
```

Static button list (three entries) — no helper extraction needed yet.

#### 3. CSS — tab chrome

**File**: `app/assets/tailwind/application.css`
**Change**: append a new section. Place after the `.app-nav` block (around line 228, before the flash-strip rules) so the studio chrome lives next to the page chrome it visually echoes.

```css
/* ============================================================
   STUDIO TABS — kanji + mono label, accent underline on active
   ============================================================ */
.tab-nav {
  display: flex;
  gap: 0;
  border-bottom: 1px solid var(--rule);
  margin: 0 0 24px;
}
.tab-button {
  appearance: none;
  background: transparent;
  border: 0;
  border-bottom: 2px solid transparent;
  cursor: pointer;
  padding: 12px 20px 14px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  color: var(--fg-muted);
  transition: color 120ms cubic-bezier(0.2, 0, 0, 1),
              border-color 120ms cubic-bezier(0.2, 0, 0, 1);
}
.tab-button:hover { color: var(--fg); }
.tab-button:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}
.tab-button__numeral {
  font-size: 28px;
  line-height: 1;
  color: inherit;
}
.tab-button__label {
  font-family: var(--hi-font-mono);
  font-size: 11px;
  font-weight: 500;
  text-transform: uppercase;
  letter-spacing: var(--tracking-caps);
  color: inherit;
}
.tab-button.is-active {
  color: var(--ink-800);
  border-bottom-color: var(--accent);
}
.tab-button.is-active .tab-button__numeral { color: var(--accent); }
```

Tokens only — no hardcoded hex. Easing matches the design system's standard `cubic-bezier(0.2, 0, 0, 1)` per `docs/02-architecture/04-design-system.md:136-137`.

#### 4. Rewrite `show.html.erb`

**File**: `app/views/projects/show.html.erb`
**Change**: replace lines 9-46 entirely. Lines 1-7 (section, turbo_stream subscription, eyebrow, h1) keep their structure; line 1's `max-width: 1600px` from Phase 1 is retained.

New file contents:

```erb
<section style="max-width: 1600px; margin: 0 auto;">
  <%= turbo_stream_from @project %>

  <div class="flex items-baseline" style="gap: 12px; margin-bottom: 16px;">
    <div class="eyebrow">studio · <span class="mono">project_<%= @project.id %></span></div>
  </div>
  <h1 class="h-section" style="margin: 0 0 24px;"><%= @project.name %></h1>

  <%= render "shared/chat_notice" %>

  <div data-controller="tabs" data-tabs-active-value="build">
    <%= render "tab_nav" %>

    <div id="pane_build"
         role="tabpanel"
         aria-labelledby="tab_build"
         tabindex="0"
         data-tabs-target="pane"
         data-tab-name="build">
      <div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">
        <% @chat_events.each do |event| %>
          <% case event %>
          <% when Message %>
            <%= render partial: "messages/message", locals: { message: event } %>
          <% when Instruction %>
            <%= render partial: "instructions/status_row", locals: { instruction: event } %>
          <% end %>
        <% end %>
      </div>
      <div style="margin-top: 16px;">
        <%= render "messages/form", project: @project %>
      </div>
    </div>

    <div id="pane_preview"
         role="tabpanel"
         aria-labelledby="tab_preview"
         tabindex="0"
         data-tabs-target="pane"
         data-tab-name="preview"
         style="display: none;">
      <div id="active_revisions">
        <%= render "revisions/list", revisions: @active_revisions %>
      </div>
      <div style="margin-top: 16px;">
        <%= render "previews/pane", project: @project %>
      </div>
    </div>

    <div id="pane_export"
         role="tabpanel"
         aria-labelledby="tab_export"
         tabindex="0"
         data-tabs-target="pane"
         data-tab-name="export"
         style="display: none;">
      <%= render "github_exports/pane", project: @project %>
    </div>
  </div>
</section>
```

What changed from the current file:
- **Removed**: `grid lg:grid-cols-2 gap-6` wrapper (line 11) and `lg:sticky lg:top-4 lg:h-fit` right-column container (line 39).
- **Removed**: the duplicated inline `flash[:alert]` strip at lines 26-33. Layout-level alert at `app/views/layouts/application.html.erb:51-57` is the single source.
- **Moved**: `#active_revisions` from Build pane to Preview pane (above the iframe). Id and inner content unchanged — broadcasts at `config/initializers/event_subscribers.rb:13-18,50-55,109-114` keep landing on the same id.
- **Added**: `data-controller="tabs"` root, three `data-tabs-target="pane"` panes, `_tab_nav` partial render. Default active = `build`; `preview` and `export` panes start with inline `display: none`.
- **Unchanged**: every broadcast target id (`#messages`, `#message_<id>`, `#active_revisions`, `#revision_<id>`, `#preview`, `#github_export_pane`, `#chat_notice`, `#project_<id>_message_form`) is still present in the DOM on every render.

#### 5. Controller test — branch coverage

**File**: `test/controllers/projects_controller_show_test.rb`
**Change**: add a new section of tests for the tab DOM structure. The existing tests (lines 12-49 in the current file) already cover `#active_revisions` rendering branches; they still pass because the id is still in the document — just relocated to the Preview pane.

Verify-then-add: read the existing file fully to see the existing `setup` block (`@user = create_user; sign_in @user; @project = @user.projects.create!(name: "Shop"); @chat = @project.create_chat!; @user_message = @chat.messages.create!(role: :user, content: "flower shop")`). Reuse that setup.

```ruby
# Append after the existing tests in projects_controller_show_test.rb.

test "renders three tab buttons (build / preview / export) with kanji glyphs and mono labels" do
  get project_url(@project)
  assert_response :success
  assert_select "nav.tab-nav[role=tablist][aria-label=?]", "studio sections", 1
  assert_select "nav.tab-nav button.tab-button[data-tab-name=build]" do
    assert_select "span.tab-button__numeral.kanji", text: "一"
    assert_select "span.tab-button__label", text: /hi · 01 · build/i
  end
  assert_select "nav.tab-nav button.tab-button[data-tab-name=preview]" do
    assert_select "span.tab-button__numeral.kanji", text: "二"
    assert_select "span.tab-button__label", text: /fu · 02 · preview/i
  end
  assert_select "nav.tab-nav button.tab-button[data-tab-name=export]" do
    assert_select "span.tab-button__numeral.kanji", text: "三"
    assert_select "span.tab-button__label", text: /mi · 03 · export/i
  end
end

test "build is the default-active tab; preview and export are inactive (aria + roving tabindex)" do
  get project_url(@project)
  assert_response :success
  assert_select "button.tab-button.is-active[data-tab-name=build][aria-selected=true][tabindex=?]", "0", 1
  assert_select "button.tab-button[data-tab-name=preview][aria-selected=false][tabindex=?]", "-1", 1
  assert_select "button.tab-button[data-tab-name=export][aria-selected=false][tabindex=?]", "-1", 1
  assert_select "button.tab-button.is-active", 1   # exactly one active
end

test "tab buttons declare aria-controls pointing at their pane ids" do
  get project_url(@project)
  assert_response :success
  assert_select "button#tab_build[role=tab][aria-controls=pane_build]", 1
  assert_select "button#tab_preview[role=tab][aria-controls=pane_preview]", 1
  assert_select "button#tab_export[role=tab][aria-controls=pane_export]", 1
end

test "tab buttons wire keydown to tabs#keydown for arrow-key navigation" do
  get project_url(@project)
  assert_response :success
  # All three buttons must include both click and keydown actions on the tabs controller.
  %w[build preview export].each do |name|
    assert_select "button[data-tab-name=#{name}][data-action*=?]", "click->tabs#switch", 1
    assert_select "button[data-tab-name=#{name}][data-action*=?]", "keydown->tabs#keydown", 1
  end
end

test "all three tab panes are role=tabpanel, labelled by their tab, and present in the DOM" do
  get project_url(@project)
  assert_response :success
  assert_select "div#pane_build[role=tabpanel][aria-labelledby=tab_build][data-tab-name=build]", 1
  assert_select "div#pane_preview[role=tabpanel][aria-labelledby=tab_preview][data-tab-name=preview][style*=?]",
    "display: none", 1
  assert_select "div#pane_export[role=tabpanel][aria-labelledby=tab_export][data-tab-name=export][style*=?]",
    "display: none", 1
end

test "every Turbo broadcast target id is present in the rendered DOM" do
  # Single Action Cable subscription (turbo_stream_from @project) drives all panes
  # via plain DOM ids and one turbo frame. If any of these ids disappears from
  # the document, the corresponding broadcast becomes a silent no-op.
  get project_url(@project)
  assert_response :success
  assert_select "div#chat_notice", true,
    "chat_notice slot must exist for ChatRespondJob#broadcast_chat_notice (chat_respond_job.rb:62-69)"
  assert_select "div#active_revisions", true,
    "active_revisions slot must exist for event_subscribers.rb:13-18,50-55,109-114"
  assert_select "div#messages", true,
    "messages container must exist for Message#broadcast_append_message (message.rb:5,16-23)"
  assert_select "div#preview", true,
    "preview slot must exist for PreviewManager#broadcast (preview_manager.rb:325-332)"
  assert_select "turbo-frame#github_export_pane", true,
    "github_export_pane frame must exist for ExportToGithubJob#broadcast (export_to_github_job.rb:108-115)"
  assert_select "form#project_#{@project.id}_message_form", true,
    "message form id must exist for MessagesController#create turbo_stream response"
end

test "build pane contains the messages feed and the composer form" do
  get project_url(@project)
  assert_response :success
  # Both pinned to the same pane:
  assert_select "div#pane_build[data-tab-name=build]" do
    assert_select "div#messages", 1
    assert_select "form#project_#{@project.id}_message_form", 1
  end
end

test "preview pane contains the active_revisions list above the preview slot" do
  get project_url(@project)
  assert_response :success
  assert_select "div#pane_preview[data-tab-name=preview]" do
    assert_select "div#active_revisions", 1
    assert_select "div#preview", 1
  end
end

test "export pane contains the github_export turbo frame" do
  get project_url(@project)
  assert_response :success
  assert_select "div#pane_export[data-tab-name=export]" do
    assert_select "turbo-frame#github_export_pane", 1
  end
end

test "duplicated inline flash strip is gone; layout-level strip still renders (regression guard)" do
  # The old layout duplicated layouts/application.html.erb's :alert strip inside
  # the left/Build column at show.html.erb:26-33. Removed in the tabs refactor.
  #
  # Drive a real flash[:alert] via the MessagesController#create HTML fallback:
  # an empty content submission redirects to @project with alert "Message cannot
  # be blank." (messages_controller.rb:9-10). Following the redirect lands on
  # show with the alert actually set — exercising both halves of this guard
  # (layout strip renders, build pane does NOT duplicate it).
  post project_messages_url(@project), params: { message: { content: "" } }
  follow_redirect!
  assert_response :success
  # The layout-level strip renders:
  assert_select "main .notice-strip--err", 1
  # …but it is NOT inside the Build pane:
  assert_select "div#pane_build .notice-strip--err", 0
end
```

Branch coverage matrix (per `feedback_test_branch_coverage`):

| Branch | Test |
|---|---|
| Tab strip rendered with three buttons + tablist role | "renders three tab buttons …" |
| Default-active state + roving tabindex | "build is the default-active tab …" |
| Tabs declare aria-controls → pane ids | "tab buttons declare aria-controls …" |
| Tabs wire keydown for arrow-key nav | "tab buttons wire keydown to tabs#keydown …" |
| Panes are tabpanels labelled by their tab; preview/export hidden | "all three tab panes are role=tabpanel …" |
| Every broadcast target id present | "every Turbo broadcast target id is present …" |
| Build pane content | "build pane contains the messages feed …" |
| Preview pane content + relocated `#active_revisions` | "preview pane contains the active_revisions list …" |
| Export pane content | "export pane contains the github_export turbo frame" |
| Removed-duplicate-flash regression | "duplicated inline flash strip is gone …" |

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test test/controllers/projects_controller_show_test.rb` green; the ten new tests above all pass.
- [ ] `bundle exec rails test` full suite green.
- [ ] `bin/rails tailwindcss:build` succeeds; `app/assets/builds/tailwind.css` contains `.tab-nav` and `.tab-button.is-active`.
- [ ] `git grep -n "grid lg:grid-cols-2"` and `git grep -n "lg:sticky lg:top-4 lg:h-fit"` both return zero hits in `app/views/projects/show.html.erb`.

#### Manual:
- [ ] `bin/dev` running. Open `/projects/<id>` for a project that has at least one completed instruction (so all three panes have content). Tab strip shows 一/二/三 with mono-caps labels; Build is active (accent underline + accent kanji + dark label); Preview and Export are muted, no underline.
- [ ] Click Preview tab. Build pane disappears; Preview pane shows the revisions table on top, the preview pane (Stopped/Running state per existing logic) below. URL does not change. No network request fires (verify in DevTools Network panel).
- [ ] Click Export tab. Preview pane hides, Export pane shows the GitHub-export form (or "connect GitHub first" CTA, depending on `project.exportable?`). URL still unchanged.
- [ ] Click Build tab. Returns to messages feed + composer. The composer textarea retains any text typed before tab-switching (DOM is preserved).
- [ ] **Keyboard navigation (WAI-ARIA tabs pattern)**: Tab into the tab strip from the page (Tab key from the eyebrow). Focus lands on the active tab (Build). Press → (ArrowRight): focus and active tab move to Preview. Press → again: Export. Press → again: wraps to Build. Press End: jumps to Export. Press Home: jumps to Build. Press ← (ArrowLeft) from Build: wraps to Export. Tabbing forward from any tab moves focus *out of* the tablist and into the active panel's content (composer field, preview iframe, or export form) — not to the next tab. This is the roving-tabindex behaviour from the WAI-ARIA tabs pattern.
- [ ] **Screen reader smoke test (VoiceOver on macOS, optional)**: Cmd+F5 to enable VO; navigate to the tab strip. VO announces "studio sections, tab list, 3 items". Each tab announces "Build, tab, selected, 1 of 3" (and similar). Switching tabs via arrow keys announces the new selection.
- [ ] Submit a message from the Build composer. Form replaces (per `MessagesController#create` turbo_stream); the new user message appears at the bottom of `#messages`; tab strip stays on Build.
- [ ] While on Preview tab, send a chat message via `bin/generate respond <project_id> "say hi"` from a separate terminal (or just submit from Build, then immediately switch to Preview before the LLM finishes). Watch the `#messages` broadcast: when you switch back to Build, the assistant reply is already there.
- [ ] While on Export tab, click "Start preview" (you'll need to switch to Preview to find the button — this just confirms the buttons live in their right panes). Switch back to Export — Export pane is unaffected. Switch to Preview — pane shows `:starting` then `:running`, iframe loads the generated app.
- [ ] Trigger a `:notice` flash (sign out + sign in). Strip renders at the new 1600-px width above the tab strip. Tab strip and panes still align.
- [ ] Trigger an `:alert` (e.g. `redirect_to project_path(project), alert: "boom"` in `rails c` won't work; test the path that already produces alerts — e.g. failing GitHub-export disconnect, or just verify the layout strip still appears in the rendered HTML for a request with `flash[:alert]` set).
- [ ] Refresh the page while on Preview tab. Page reloads with Build active (no URL state).
- [ ] Resize browser narrower than 1024 px. Tab strip remains horizontal (no `grid lg:` rule applies anymore — the grid is gone). Confirm tabs still render side-by-side at e.g. 720 px width; if labels overflow, accept it for this iteration (per `feedback_planning_interaction_style`-style scope discipline, no responsive tab collapse is in this plan).

**Pause for manual confirmation. The change is shipped once both phases pass their manual gates.**

---

## Testing Strategy

### Unit Tests
- No new model/job/helper code — no new unit tests required.

### Controller Tests
- All in `test/controllers/projects_controller_show_test.rb` (extends the existing file). Eight new tests as listed above. They cover the DOM contract end-to-end without booting a browser.

### Integration / System Tests
- **None.** The feature is a pure DOM toggle with no server-side state change. Per `project_verify_no_system_tests` and the absence of `test/system/` in this repo, behavior of the Stimulus toggle itself is verified by the manual gate.
- The existing `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` and `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb` should pass unchanged — they don't assert on layout.

### Manual Testing
- The Phase 1 and Phase 2 manual-verification checklists above are the manual-test plan.

## Performance Considerations

- All three panes render server-side on every `show`. Since the right column already rendered both the Preview pane *and* the Export pane on every show before this change, the only new work is rendering `#messages` + composer + revisions table when none of them changed. For a project with N messages, that's the same template cost as before. No new DB queries: `@chat_events` and `@active_revisions` are already loaded by `ProjectsController#show` (`app/controllers/projects_controller.rb:30-33,49-54,56-62`).
- The Stimulus controller adds <50 lines of JS; eager-loaded with the rest of `controllers/`. Negligible.
- Hiding tabs via inline `display: none` is style-only. Action Cable continues to receive and apply Turbo Stream actions to hidden DOM subtrees — this is exactly the property we want and confirmed in the `Open Questions` section of the research doc.

## Migration Notes

- No data migration. No schema change. No deploy ordering constraint.
- Browser cache: the CSS file changes. The `data-turbo-track="reload"` on the stylesheet link in `application.html.erb:23` causes Turbo to do a full reload when the stylesheet hash changes, so users on stale pages get the new CSS automatically on next click.
- An open browser tab on `/projects/:id` at the moment of deploy will continue running with the old DOM (single column, 1120 px) until the user navigates. Action Cable broadcasts targeting unchanged ids (`#messages`, `#preview`, etc.) keep landing in the old DOM correctly. A reload picks up the new layout.

## References

- Research: `thoughts/shared/research/2026-05-08/authenticated-screens-layout-and-project-show-tabs.md` — width topology, broadcast wiring, archive context.
- Design canon: `docs/02-architecture/04-design-system.md` — token map, component conventions, anti-patterns.
- Pattern precedent (Stimulus controller wired via data-action + targets): `app/javascript/controllers/suggestions_controller.js`, `app/views/projects/new.html.erb:1,29-32`.
- Pattern precedent (kanji + mono-eyebrow + numeral composition): `app/views/home/index.html.erb:18-49`, CSS at `app/assets/tailwind/application.css:687-735`.
- Manual-verification format precedent: `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:245-256` (Step 1 Automated/Manual block).
- Convention: `feedback_test_branch_coverage` (one test per logical branch); `project_verify_no_system_tests` (no Selenium); `feedback_no_logic_in_views` (tab buttons stay declarative — no helper needed for three static entries); `project_form_replace_over_redirect` (composer submission still replaces the form via turbo_stream — preserved).
- Broadcast targets verified live in code:
  - `app/jobs/chat_respond_job.rb:62-69` → `#chat_notice`
  - `config/initializers/event_subscribers.rb:13-18,50-55,109-114` → `#active_revisions`
  - `app/models/message.rb:5,16-23` → `#messages` and `#message_<id>`
  - `lib/preview/preview_manager.rb:325-332` → `#preview`
  - `app/jobs/export_to_github_job.rb:108-115` → `#github_export_pane`
  - `app/controllers/messages_controller.rb:4-22` → `#project_<id>_message_form`
