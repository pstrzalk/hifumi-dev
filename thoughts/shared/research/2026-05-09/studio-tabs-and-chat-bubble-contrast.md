---
date: 2026-05-09T10:51:05+0200
researcher: Paweł Strzałkowski
git_commit: 2dca4d329aa89e8bf5a4c82efb86eac17254f08d
branch: studio-tabs-and-1600-shell
repository: rails-app-generator
topic: "Studio tabs + chat-bubble contrast — knowledge base for visual optimization"
tags: [research, codebase, studio, tabs, chat-bubble, hifumi, design-system, contrast]
status: complete
last_updated: 2026-05-09
last_updated_by: Paweł Strzałkowski
---

# Research: Studio tabs + chat-bubble contrast — knowledge base for visual optimization

**Date**: 2026-05-09T10:51:05+0200
**Researcher**: Paweł Strzałkowski
**Git Commit**: 2dca4d329aa89e8bf5a4c82efb86eac17254f08d
**Branch**: studio-tabs-and-1600-shell
**Repository**: rails-app-generator

## Research Question

The studio screen (`/projects/:id`) has visually weak chrome. Specifically:
- Three tabs (BUILD / PREVIEW / EXPORT) are not visually distinctive — the active tab is signalled only by a 2px accent underline and a kanji-glyph color shift; non-active tabs don't read as tabs.
- Tabs hug the left edge instead of spanning the full width of the studio shell — the user wants each tab to occupy 1/3 of the strip width.
- Chat bubbles are barely visible against the page background — user bubbles use `--paper-0` (#FFFFFF), assistant bubbles use `--bg-elevated` (which resolves to `--paper-50`, #FDFBF7); the page sits on `--paper-100` (#FAF7F2). The deltas are 5/255 and 3/255 respectively.

This document maps every file/class/token involved, plus the design-system constraints any change must respect. **It documents what exists; it does not propose changes.**

## Summary

The tab strip is a hand-authored `.tab-nav` + `.tab-button` block (no library), driven by a Stimulus `tabs_controller` that toggles `is-active` + ARIA + inline `display: none`. The active state is currently expressed through three style deltas (border-bottom color, label color, kanji color) — no surface change. The strip uses `display: flex; gap: 0` with no explicit width on each button, so the strip's intrinsic width is the sum of three padded buttons, leaving whitespace to the right.

Chat bubbles render via `app/views/messages/_message.html.erb` for messages and `app/views/instructions/_status_row.html.erb` for build-status rows. Both use the same `msg-bubble` shell. Backgrounds are `--paper-0` (user, white) and `--bg-elevated` (assistant, near-paper). The `1px solid var(--border)` ring provides almost all the perceptual definition of the bubble; against `--paper-100` the surface fill provides essentially none.

The Hifumi token palette has surfaces ranging from `--paper-0` (#FFFFFF) through `--paper-300` (#E6DFD1) and ink tiers `--ink-50` (#F4F1ED) → `--ink-900` (#0E0C0A). Constraints: no hardcoded hex, no gradients/glassmorphism/big shadows, no emoji, sentence case, and `--accent` ("use sparingly") is the only saturated colour.

## Detailed Findings

### Tab strip — markup

**`app/views/projects/_tab_nav.html.erb`** (33 lines, full file).

```erb
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

Notes:
- Initial active tab is hard-coded to `:build` at render time (line 18). The Stimulus value `data-tabs-active-value="build"` in `show.html.erb:11` must agree.
- Each tab is a `<button>`, not an `<a>` — no URL state, no deep-linking.
- The kanji span carries both `tab-button__numeral` and `kanji` classes (the latter sets Source Serif 4 + 0.06em tracking — see `application.css:176-180`).

### Tab strip — Stimulus controller

**`app/javascript/controllers/tabs_controller.js`** (60 lines).

- Targets: `tab` (buttons), `pane` (panels). Value: `active` (string, default `"build"`).
- `connect()` (15-17) calls `render()` to sync DOM to value.
- `switch(event)` (19-24) reads `event.currentTarget.dataset.tabName` → assigns `this.activeValue` → focuses the new tab.
- `keydown(event)` (26-43) handles `ArrowLeft / ArrowRight / Home / End` with modulo arithmetic on `this.tabTargets`.
- `activeValueChanged()` (45-47) → `render()`.
- `render()` (49-60):
  - Tabs: `el.classList.toggle("is-active", isActive)`, `el.setAttribute("aria-selected", ...)`, `el.setAttribute("tabindex", "0"|"-1")`.
  - Panes: `el.style.display = ""` or `"none"` — set as **inline style**, not a class. Any CSS that wants to control pane visibility competes with this inline style.

### Tab strip — CSS

**`app/assets/tailwind/application.css:240-283`**, current state (post the typography bump that landed without flipping `thoughts/shared/plans/2026-05-09/typography-ramp-bump.md` out of `draft`):

```css
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
.tab-button__numeral { font-size: 44px; line-height: 1; color: inherit; }
.tab-button__label {
  font-family: var(--hi-font-mono);
  font-size: 18px;
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

**Width behaviour today.** No `flex` or `width` on `.tab-button`. Each button shrinks to its content + `padding: 12px 20px 14px`. `.tab-nav` has `gap: 0` and no `width: 100%` (it inherits the natural block width of its parent inside the studio `<section style="max-width: 1600px">`). The strip therefore appears as three left-clustered tabs with a long bare hairline trailing to the right — visible in the user's screenshot.

**Active-state signal channels (current).**
- `.tab-button.is-active` text color: `var(--fg-muted)` → `var(--ink-800)` — small contrast bump.
- `.tab-button.is-active` border-bottom color: `transparent` → `var(--accent)` (#CC0000) — 2px stripe.
- `.tab-button.is-active .tab-button__numeral` color: inherit (`--fg-muted`) → `var(--accent)`.
- No background change. No padding change. No border on the other three sides.

**Focus-visible signal.** A 2px solid `--accent` outline with 2px offset (independent of `is-active`).

### Studio shell context for the tab strip

**`app/views/projects/show.html.erb:1-60`**.

- Outer `<section style="max-width: 1600px; margin: 0 auto;">` (line 1).
- Title block (lines 4-7): eyebrow `studio · project_<id>` + `.h-section` h1 with the project name.
- Tab container at line 11: `<div data-controller="tabs" data-tabs-active-value="build">`.
- Tab nav rendered via `<%= render "tab_nav" %>` (line 12).
- Three `<div>` panes follow (lines 14-58), each `role="tabpanel"`, `aria-labelledby`, `tabindex="0"`, `data-tabs-target="pane"`. The non-build panes ship with `style="display: none;"` inline (lines 41 and 56).
- Build pane contents (lines 14-33):
  - `<div id="messages" class="flex flex-col" style="gap: 12px; margin-bottom: 16px;">` — chat stream
  - Iterates `@chat_events`, rendering `messages/message` or `instructions/status_row` per event
  - Composer at line 31: `<%= render "messages/form", project: @project %>`

### Chat bubble — message partial

**`app/views/messages/_message.html.erb`** (14 lines, full file).

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

### Chat bubble — helpers

**`app/helpers/messages_helper.rb:2-6`** — `message_row_class(message)`:
- `"hidden"` if not `visible_in_chat?`
- `"msg msg-user"` if role == "user"
- `"msg msg-asst"` otherwise (in practice, "assistant")

**`app/helpers/messages_helper.rb:8-17`** — `tool_call_pill_text(message)`:
- For `create_application` / `modify_application`: returns `"🌀 Build started: <intent>"` (or `"🌀 Build started"` if intent blank).
- For any other tool: `"running: <comma-joined unique tool names>"`.
- Note: this helper still emits the `🌀` emoji literal — pre-Hifumi pattern that survives in pill copy.

**`app/models/message.rb:8-12`** — `visible_in_chat?`:
- `false` if `system_injected?`.
- `true` if role == "user".
- For assistant: `true` only if content present OR `tool_calls.any?`.

### Chat bubble — instruction status row

**`app/views/instructions/_status_row.html.erb`** (16 lines).

Wrapper: `<div id="<dom_id>_status" class="msg msg-asst">` — uses the same row classes as an assistant message, so the bubble is left-aligned in the stream.

Inner: a single `<div class="msg-bubble">` containing only a `<div class="msg-pill">`. The pill text is one of:
- `"✅ Built"` (completed)
- `"❌ Build failed: <summary>"` (failed with a failed revision)
- `"❌ Build failed"` (failed without one)

No `msg-role` label, no `msg-body`. The `.msg-pill::before` blinking dot sits left of the emoji. (Per memory: emoji status here are legacy and being phased out toward the rectangular outlined `.tag` pattern; this partial has not been migrated.)

### Chat bubble — CSS

**`app/assets/tailwind/application.css:586-623`**, current state:

```css
.msg { display: flex; }
.msg-user { justify-content: flex-end; }
.msg-asst { justify-content: flex-start; }

.msg-bubble {
  max-width: 80%;
  padding: 10px 14px;
  border-radius: var(--radius-md);   /* 6px */
  border: 1px solid var(--border);   /* var(--ink-100) = #E4DFD8 */
  background: var(--paper-0);        /* #FFFFFF — user bubble */
}
.msg-asst .msg-bubble { background: var(--bg-elevated); }  /* var(--paper-50) = #FDFBF7 */

.msg-role {
  font-family: var(--hi-font-mono);
  font-size: 16px;
  color: var(--fg-faint);    /* var(--ink-400) = #756D62 */
  text-transform: uppercase;
  letter-spacing: var(--tracking-caps);
  margin-bottom: 4px;
}
.msg-body { color: var(--fg); white-space: pre-wrap; line-height: 1.55; }

.msg-pill {
  font-family: var(--hi-font-mono);
  font-size: 20px;
  color: var(--fg-muted);
  font-style: normal;
  display: inline-flex;
  align-items: center;
  gap: 8px;
}
.msg-pill::before {
  content: "";
  display: inline-block;
  width: 6px;
  height: 6px;
  background: var(--accent);
  animation: hi-blink 1.6s ease-in-out infinite;
}
```

**Computed contrast on the studio canvas (`--paper-100` = #FAF7F2):**
- User bubble fill `--paper-0` (#FFFFFF) vs canvas: ΔL ≈ 2.5/100. Effectively invisible without the border.
- Assistant bubble fill `--paper-50` (#FDFBF7) vs canvas: ΔL ≈ 1.5/100. Effectively invisible without the border.
- Bubble border `--ink-100` (#E4DFD8) vs canvas: ΔL ≈ 8/100. This 1px hairline carries 100% of the perceived bubble outline.
- `.msg-body` text `--fg` (`--ink-800` = #1A1714) vs either bubble fill: high contrast — body copy reads fine; only the *bubble shape* is faint.

### Composer

**`app/views/messages/_form.html.erb`** uses `form_with(class: "composer")` containing a `<input class="field-input">` and a submit `<button class="btn btn--primary">`. CSS at `application.css:628-629`: `.composer { display: flex; gap: 8px; }` / `.composer .field-input { flex: 1; }`. `.btn--primary` (`application.css:370`) is `background: var(--ink-800); color: var(--fg-on-accent);` — high-contrast solid black-ish CTA.

The studio composer does **not** render the suggestion-chip strip. `.composer-suggestions` / `.suggestion-chip` (CSS at 630-647) appear only on `app/views/projects/new.html.erb:27-36`.

### Chat notice strip

**`app/views/shared/_chat_notice.html.erb`** renders `<div id="chat_notice">` and, when `local_assigns[:message]` is present, a `.notice-strip.notice-strip--err` block. The notice is **above** the tab strip in `show.html.erb:9` — outside the tabbed area.

## Code References

- `app/views/projects/_tab_nav.html.erb:1-33` — tab markup and active-tab seeding
- `app/views/projects/show.html.erb:1-60` — studio layout, panes, `data-tabs-active-value`
- `app/javascript/controllers/tabs_controller.js:1-60` — switch / keydown / render lifecycle
- `app/assets/tailwind/application.css:240-283` — `.tab-nav`, `.tab-button`, `.tab-button.is-active`
- `app/assets/tailwind/application.css:9-105` — root token map (palette, semantic, type, radius, motion)
- `app/assets/tailwind/application.css:586-623` — `.msg`, `.msg-bubble`, `.msg-role`, `.msg-body`, `.msg-pill`
- `app/views/messages/_message.html.erb:1-14` — message bubble markup
- `app/views/messages/_form.html.erb` — composer
- `app/views/instructions/_status_row.html.erb:1-16` — build-status row (uses `msg msg-asst` + `msg-bubble` + `msg-pill`)
- `app/views/shared/_chat_notice.html.erb` — error strip above the tabs
- `app/helpers/messages_helper.rb:2-17` — `message_row_class`, `tool_call_pill_text`
- `app/models/message.rb:8-12` — `visible_in_chat?`

## Architecture Documentation

### Hifumi palette tokens currently defined (application.css:9-105)

**Surfaces (warm).** `--paper-0` #FFFFFF, `--paper-50` #FDFBF7, `--paper-100` #FAF7F2 (page bg), `--paper-200` #F2EDE3, `--paper-300` #E6DFD1.

**Ink (warm near-blacks).** `--ink-50` #F4F1ED, `--ink-100` #E4DFD8 (= `--border`), `--ink-200` #C9C2B8 (= `--border-strong`), `--ink-300` #A39B90, `--ink-400` #756D62 (= `--fg-faint`), `--ink-500` #4F4940 (= `--fg-muted`), `--ink-600` #332E27, `--ink-700` #221E18, `--ink-800` #1A1714 (= `--fg`), `--ink-900` #0E0C0A.

**Accent (use sparingly).** `--rails-50` #FFF1F0 (= `--accent-soft`), `--rails-100` #FFD9D6, `--rails-200` #FFB1AA (= `--accent-line`), `--rails-300` #FF7A6E, `--rails-400` #E84034, `--rails-500` #CC0000 (= `--accent`), `--rails-600` #A50000 (= `--accent-hover`), `--rails-700` #7A0303, `--rails-800` #4D0606.

**Steel (technical neutrals — code only).** `--steel-50` #F4F6F8, `--steel-100` #E6EAEE, `--steel-200` #C8D0D9, `--steel-300` #8E97A2, `--steel-700` #2A3038, `--steel-800` #1B1F25, `--steel-900` #0F1216 (= `--bg-code`).

**Status (desaturated).** `--ok-bg` / `--ok-fg` / `--ok-line`, `--info-bg` / `--info-fg`, `--warn-bg` / `--warn-fg` / `--warn-line`, `--err-bg` / `--err-fg`.

**Semantic aliases.** `--bg` = `--paper-100`, `--bg-elevated` = `--paper-50`, `--bg-sunken` = `--paper-200`, `--bg-inverse` = `--ink-800`, `--bg-code` = `--steel-900`. `--fg` = `--ink-800`, `--fg-muted` = `--ink-500`, `--fg-faint` = `--ink-400`, `--fg-inverse` = `--paper-50`, `--fg-on-accent` = `#FFFFFF`. `--border` = `--ink-100`, `--border-strong` = `--ink-200`, `--border-faint` = `--paper-300`, `--rule` = `--ink-100`.

**Radii.** `--radius-sm` 4px, `--radius-md` 6px, `--radius-lg` 10px, `--radius-pill` 999px.

**Type families.** `--hi-font-sans` (IBM Plex Sans), `--hi-font-mono` (IBM Plex Mono), `--hi-font-serif` (Source Serif 4).

**Motion.** `--ease-standard` `cubic-bezier(0.2, 0, 0, 1)`, `--dur-fast` 120ms, `--dur-base` 180ms.

### Patterns already used in the codebase that touch the same problem space

- **Two-tone surface contrast**, used in `.notice-strip` (application.css:288-310): `background: var(--paper-0)` for the body card, `background: var(--bg-elevated)` for the tag column — i.e. paper-0 against paper-50 inside a single component.
- **Stripe + outlined tag** for status (the canonical Hifumi pattern): used by `.notice-strip__stripe`, `.project-card__stripe`, `.revision-row .stripe`, all 4px wide on the left edge, color modulated per status (ok/info/warn/err). The chat-bubble component does not currently use a stripe.
- **Active-link signal** in the top nav (`application.css:235`): `.app-nav-link.active { color: var(--accent); border-bottom: 2px solid var(--accent); padding-bottom: 4px; }` — the same accent-underline pattern the tab strip already uses.
- **Inverse surface**: `.btn--primary` uses `background: var(--ink-800)` with `color: var(--fg-on-accent)` (white). `--bg-inverse` = `--ink-800` is defined but only `.btn--primary` consumes it. No surface in the chat stream currently uses an inverse fill.
- **Three-column equal-width strip** with hairline dividers: `.pipeline` (application.css:738-760) does `grid-template-columns: repeat(3, 1fr)` plus `border-right: 1px solid var(--border)` between cells. Same shape as a 1/3-each tab row — it just uses grid rather than `flex: 1`.

### Constraints from the design canon (`docs/02-architecture/04-design-system.md`)

- **Tokens only — never hardcode hex.**
- **No gradients, no glassmorphism, no large drop-shadows, no rounded-corner + colored-left-border cards.** Use a 1px hairline before reaching for a shadow.
- **Standard easing only**: `cubic-bezier(0.2, 0, 0, 1)`. No bouncy/springy curves.
- **Sentence case** in every UI string. **No emoji** (with documented legacy exceptions; the `🌀 / ✅ / ❌` in `tool_call_pill_text` and `_status_row` are legacy).
- **Status indicators** are rectangular outlined boxes in mono caps with a stripe + blinking dot — not pastel-filled pills.
- **All typography lives in `application.css`** — zero `text-*` Tailwind utilities anywhere under `app/views/` (verified by `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md`).
- **`--accent` (Rails red) is used sparingly** — currently allocated to: top-nav active link, tab-button active border + active numeral, `.notice-strip--err` stripe, `.tag--err` / `.tag--failed`, `.msg-pill::before` blinking dot, `.preview-pane__url:hover`, `.pipeline-step__numeral`, `.btn--accent`, `.h-section ::selection`, focus rings.

### Empty / undocumented spots

- `--bg-elevated` is defined in the CSS root but is **not** enumerated in the design system doc's published token table. It currently maps to `--paper-50`.
- `.msg-body` declares no `font-size` — it inherits the body baseline (22px after the typography bump).
- The tab strip has no documented decision on equal-thirds vs left-clustered layout (see "Historical Context" below). Both are stylistically open.
- The chat bubble has no documented decision on contrast. The original Hifumi rollout (`6c9234d design: apply Hifumi design system across visible chrome`) shipped the current `--paper-0` / `--bg-elevated` pairing without a recorded rationale.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-05-08/studio-tabs-and-1600-shell.md` — original plan that introduced the tab strip (commit `4b7e470`) and widened the studio shell to 1600px. Specifies `gap: 0`, accent-bottom-border active state, kanji + mono label composition. Does **not** address equal-thirds width or chat-bubble surface choice.
- `thoughts/shared/plans/2026-05-09/typography-ramp-bump.md` — status `draft`, but the bumped values (body 22px, `.tab-button__numeral` 44px, `.tab-button__label` 18px, `.msg-role` 16px, `.msg-pill` 20px) are already live in `application.css`. The plan's old/new tables are still useful for cross-referencing sizes.
- `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md` — confirms that no template uses Tailwind `text-*` utilities; all type changes must land in `application.css`.
- `docs/02-architecture/04-design-system.md` — Hifumi canon. Token map, anti-patterns, status-tag rules, sentence-case rule, "no emoji" rule.
- `CLAUDE.md` (project root) — repeats: "All visible chrome follows the Hifumi design system. Tokens + component classes live in a single file: `app/assets/tailwind/application.css`. Use the tokens — never hardcode hex values."
- Relevant commits in chronological order:
  - `6c9234d` — initial Hifumi rollout across visible chrome (introduced `.msg-bubble` with `--paper-0` / `--bg-elevated`).
  - `4b7e470` — studio tabs replace the prior two-column grid; introduces `.tab-nav` / `.tab-button` exactly as documented above.
  - `c25e8e0` — widens the authenticated shell to 1600px (the `style="max-width: 1600px"` on the studio `<section>`).
  - `b3d7b7c` / `2dca4d3` — non-studio chrome work, cited only because the working tree contains uncommitted Devise + composer-form + `application.css` edits from those follow-ups; they don't touch the tab strip or message bubble.

## Related Research

- `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md` — full font-size landscape and the file that gates type changes.
- `thoughts/shared/plans/2026-05-08/studio-tabs-and-1600-shell.md` — origin of the current tab strip.
- `thoughts/shared/plans/2026-05-09/typography-ramp-bump.md` — typography scale (already partially shipped).

## Open Questions

These are unresolved by anything in the codebase or the docs — the optimization plan that follows this research will need to make an explicit call on each:

1. **Tab strip width strategy.** No prior decision. Options visible elsewhere in the codebase: `flex: 1` on each `.tab-button` (cheap, no markup change) vs a grid container like `.pipeline` (`grid-template-columns: repeat(3, 1fr)`). Either fits the palette and patterns; choosing depends on whether vertical hairline dividers between tabs are wanted.
2. **Active-tab signal.** The current implementation uses three weak channels (text color, border-bottom, numeral color). Available palette moves that don't break the canon: surface flip (e.g. `--paper-0` background on the active tab against the `--paper-100` page), thicker bottom border, top accent stripe (parallels `.notice-strip__stripe` and `.project-card__stripe`), or kanji-numeral weight/scale change. None has prior precedent for tabs specifically.
3. **Chat-bubble contrast.** Current paper-0/paper-50 fills both sit within 5/255 of `--paper-100`. Available palette moves without new tokens: shift assistant to `--paper-200` (#F2EDE3) or `--paper-300` (#E6DFD1) for more depth; shift user to `--bg-inverse` (`--ink-800`) with `--fg-on-accent` text (mirrors `.btn--primary`); strengthen the bubble border to `--border-strong` (`--ink-200`); add a left stripe in the canonical Hifumi pattern. No prior decision.
4. **Studio canvas.** A change to `--bg` for the studio shell (e.g. `--paper-200`) would simultaneously increase chat-bubble contrast and active-tab contrast without touching either component, but would diverge from the rest of the app which sits on `--paper-100`. No prior decision.
5. **Legacy emoji in `tool_call_pill_text` and `_status_row`** (`🌀 / ✅ / ❌`) — outside the scope of this contrast question, but they violate the "no emoji" canon and are visible in the same screen the user is critiquing.
