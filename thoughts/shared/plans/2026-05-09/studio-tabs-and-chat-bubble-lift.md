---
date: 2026-05-09
author: Paweł Strzałkowski
git_commit: 2dca4d329aa89e8bf5a4c82efb86eac17254f08d
branch: studio-tabs-and-1600-shell
repository: rails-app-generator
topic: "Studio tabs + chat bubbles — Lift design"
tags: [plan, studio, tabs, chat-bubble, hifumi, design-system, lift]
status: draft
last_updated: 2026-05-09
last_updated_by: Paweł Strzałkowski
research: thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md
---

# Studio tabs + chat bubbles — "Lift" design

## Overview

Make the studio's three tabs (BUILD / PREVIEW / EXPORT) read unmistakably as a tab control, and make chat bubbles carry their own visual weight. Single coherent design language: **content surfaces lift off the page**. The active tab, the assistant bubble, and the composer share `paper-0` (white-ish) as their surface, against the studio's `paper-100` page. The user bubble inverts to `ink-800` (near-black with white text) for unmistakable send/receive identity. Studio canvas, page chrome, typography, and tokens are unchanged.

## Current State Analysis

**Tabs** (`app/assets/tailwind/application.css:240-283`, `app/views/projects/_tab_nav.html.erb:1-33`).
- Three `<button>` elements in a `flex; gap: 0;` strip, each shrinks to its content + `padding: 12px 20px 14px`. The strip therefore left-clusters; ~60% of the strip's width is empty.
- Active state expressed through three weak channels: text color (`--fg-muted` → `--ink-800`), kanji color (inherit → `--accent`), and a 2px accent bottom border. No surface change. Inactive tabs don't read as tabs at rest.
- The strip's bottom rule (`border-bottom: 1px solid var(--rule)` on `.tab-nav`) is continuous under all three tabs — there's no break to anchor the active tab to the pane below.

**Chat bubbles** (`app/assets/tailwind/application.css:586-623`, `app/views/messages/_message.html.erb`, `app/views/instructions/_status_row.html.erb`).
- User bubble fill `--paper-0` (#FFFFFF) vs page `--paper-100` (#FAF7F2): ΔL ≈ 2.5/100. Effectively invisible without the border.
- Assistant bubble fill `--bg-elevated` (= `--paper-50`, #FDFBF7) vs page: ΔL ≈ 1.5/100.
- The 1px `--border` (`--ink-100`) hairline carries 100% of the perceived bubble outline; remove it and the bubbles disappear into the page.
- Sender identity is signalled only by alignment (right vs left). Color/surface tells you nothing.

**Composer** (`app/views/messages/_form.html.erb`, `app/assets/tailwind/application.css:628-629`).
- `.composer` is `display: flex; gap: 8px;` — no background, no border, no surface of its own.
- The `.field-input` brings its own paper-0 fill + ink-200 border — it carries the visual frame on its own.
- Composer reads as detached from the chat above it.

## Desired End State

The studio shell after this plan:

- **Tabs span full width**, each tab occupying exactly 1/3. Active tab is a paper-0 card with a 1px hairline on top + left + right and a 3px `--accent` (Rails red) line on the bottom. The strip's continuous bottom rule is broken under the active tab — the accent line replaces it on that segment, joining the tab visually to the pane below. Inactive tabs sit transparent on the page, with a 1px hairline only on the bottom (continuous with the segments under their neighbours).
- **User bubbles** render as `--bg-inverse` (`--ink-800`) blocks with white text, no border, no role label. Visually mirror `.btn--primary`. Right-aligned.
- **Assistant bubbles** render as `paper-0` cards with `--border-strong` (`--ink-200`) — same surface as the active tab, slightly stronger border than today. Role label, body, and tool-call pill all stay on this surface. Status rows (✅ Built, ❌ Build failed, 🌀 Build started) inherit this surface automatically.
- **Composer** renders as a paper-0 card with `--border-strong` and padding. The text input is borderless inside it (the wrapper provides the frame). Focus is signalled by the wrapper's `border-color` shifting to `--accent` plus the standard `--focus-ring` shadow, via `:focus-within`.

### Verification:
- Visual diff against the current `/projects/:id` screen in dev — tabs span full width, active tab reads as a card joined to the pane below, user bubbles are dark, assistant bubbles + composer share a clean paper-0 surface family.
- No regressions on `/`, `/projects/new`, `/projects` (public pages) — no shared classes change semantics outside the studio.
- Test suite green: `bin/rails test`.

### Key Discoveries:
- The "folder card" tab pattern requires the bottom rule to live on each `.tab-button` (so the active button can override its own segment with the 3px accent), not on `.tab-nav`. This is a one-line move.
- `.composer` has only one consumer in the codebase (`app/views/messages/_form.html.erb:1`), so enhancing the class directly is safe — no new wrapper class or markup change needed.
- `.msg-role` is rendered for every bubble. Hiding it on user bubbles via CSS (`.msg-user .msg-role { display: none; }`) avoids any ERB change.
- `.field-input` currently brings its own paper-0 fill + ink-200 border. To make it look right inside the composer card, it needs scoped overrides (`.composer .field-input { background: transparent; border: 0; }`) — global `.field-input` rules stay untouched so other forms (devise, github_exports) are unaffected.

## What We're NOT Doing

- **Studio canvas remains `--paper-100`.** No divergence from the rest of the site.
- **Tab markup (`_tab_nav.html.erb`) and the Stimulus controller (`tabs_controller.js`) are unchanged.** All visual changes land in CSS.
- **No new design tokens.** All colors come from existing `--paper-0`, `--paper-100`, `--ink-100`, `--ink-200`, `--ink-800`, `--accent`, `--fg-on-accent`, `--border-strong`.
- **Legacy emoji status pills (`🌀 / ✅ / ❌`)** in `tool_call_pill_text` (`app/helpers/messages_helper.rb`) and `_status_row.html.erb` are out of scope. They will inherit the new bubble surface automatically; replacing them with canonical `.tag` rectangles is tracked separately in the Phase 5 candidates list.
- **Asymmetric bubble corners** (chat-app convention where the sender side has a squared corner). Keep `--radius-md` symmetric on all bubbles.
- **No left stripe on the assistant bubble.** The inverse user bubble already does the heavy contrast work; a stripe would compete.
- **No suggestion-chip strip** added to the studio composer (it's only on `/projects/new`).

## Implementation Approach

Three independent CSS-only commits, in order. Each is reviewable and ships visible value alone — Phase 1 could merge without Phase 2 if needed.

The whole change is an additive/replacement edit on `app/assets/tailwind/application.css`. No view markup, no Stimulus controller, no helper, no model touched.

---

## Phase 1: Studio tabs become folder cards across thirds

### Commit
`design: studio tabs as folder cards across full width`

### Overview
Make tabs span the full strip width (1/3 each), and turn the active tab into a paper-0 card framed by a top/left/right hairline plus a 3px accent bottom that overpaints the strip's bottom rule on its segment.

### Changes Required:

#### 1. `.tab-nav` — drop the strip's bottom rule
**File**: `app/assets/tailwind/application.css:240-245`
**Change**: Remove `border-bottom`. Each tab will draw its own bottom segment.

```css
.tab-nav {
  display: flex;
  gap: 0;
  margin: 0 0 24px;
}
```

#### 2. `.tab-button` — equal thirds + own bottom segment
**File**: `app/assets/tailwind/application.css:246-260`
**Change**: Add `flex: 1 1 0;` so each button claims one third. Replace the `border-bottom: 2px solid transparent;` with `border-bottom: 1px solid var(--rule);` so each inactive tab draws its own segment of the strip's hairline. Keep padding/colors/transition.

```css
.tab-button {
  appearance: none;
  background: transparent;
  border: 0;
  border-bottom: 1px solid var(--rule);
  flex: 1 1 0;
  cursor: pointer;
  padding: 12px 20px 14px;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  color: var(--fg-muted);
  transition: color var(--dur-fast) var(--ease-standard),
              background-color var(--dur-fast) var(--ease-standard),
              border-color var(--dur-fast) var(--ease-standard);
}
```

#### 3. `.tab-button.is-active` — folder card
**File**: `app/assets/tailwind/application.css:279-283`
**Change**: Replace the active state. Add paper-0 fill, hairlines on top/left/right, 3px accent on bottom.

```css
.tab-button.is-active {
  background: var(--paper-0);
  color: var(--ink-800);
  border-top: 1px solid var(--border);
  border-left: 1px solid var(--border);
  border-right: 1px solid var(--border);
  border-bottom: 3px solid var(--accent);
}
.tab-button.is-active .tab-button__numeral { color: var(--accent); }
```

Padding compensation: the active tab gains 1px on three sides + 2px on the bottom (3px accent vs 1px rule on inactive). To keep glyph alignment, reduce active-tab padding by these amounts.

```css
.tab-button.is-active {
  /* … */
  padding: 11px 19px 12px;
}
```

### Success Criteria:

#### Automated Verification:
- [x] Tailwind builds cleanly: `bin/rails tailwindcss:build`
- [x] Test suite green: `bin/rails test`
- [x] No Tailwind utility classes leaked into views (none should change here): `grep -rn 'class=.*tab-' app/views/projects/`

#### Manual Verification:
- [x] At `/projects/:id`, the three tabs span the full width of the studio shell, each occupying exactly 1/3.
- [x] Active tab (BUILD on initial load) reads as a paper-0 card with a hairline on top + left + right and a clear accent line on the bottom that visually joins the pane below.
- [x] The strip's bottom rule is continuous under inactive tabs and broken under the active tab.
- [x] Clicking PREVIEW or EXPORT moves the card; the previously-active tab cleanly drops back to the inactive style.
- [x] Keyboard navigation still works: `ArrowLeft / ArrowRight / Home / End` cycles tabs.
- [x] `:focus-visible` outline (2px accent + 2px offset) still visible when tabbing in.
- [x] No visible jitter on glyph/label position when switching active tab (padding compensation is correct).

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation of the visual before proceeding to Phase 2.

---

## Phase 2: Chat bubbles — inverse user, elevated assistant

### Commit
`design: invert user chat bubbles, elevate assistant to paper-0`

### Overview
Switch user bubbles to `--bg-inverse` (ink-800) with white text and no border or role label. Switch assistant bubbles to `paper-0` (matches the active-tab surface) with `--border-strong`. The bubble shape now reads at a glance, and sender identity is unambiguous.

### Changes Required:

#### 1. `.msg-bubble` — bump to stronger border
**File**: `app/assets/tailwind/application.css:590-596`
**Change**: Replace `border: 1px solid var(--border)` with `border: 1px solid var(--border-strong)`. Keep paper-0 fill (which is the assistant default after the next change).

```css
.msg-bubble {
  max-width: 80%;
  padding: 10px 14px;
  border-radius: var(--radius-md);
  border: 1px solid var(--border-strong);
  background: var(--paper-0);
}
```

#### 2. `.msg-asst .msg-bubble` — drop the per-role override
**File**: `app/assets/tailwind/application.css:597`
**Change**: Delete this rule. The default `.msg-bubble` is now paper-0; no override needed for assistant.

```css
/* line removed:
.msg-asst .msg-bubble { background: var(--bg-elevated); }
*/
```

#### 3. `.msg-user .msg-bubble` — invert
**File**: `app/assets/tailwind/application.css` (new rule, after `.msg-bubble`)
**Change**: Add user-specific overrides. ink-800 background, white text, no border. Bubble role label is hidden.

```css
.msg-user .msg-bubble {
  background: var(--bg-inverse);
  color: var(--fg-on-accent);
  border-color: transparent;
}
.msg-user .msg-role { display: none; }
.msg-user .msg-body { color: var(--fg-on-accent); }
```

(`.msg-body` currently sets `color: var(--fg)` — overriding it for the user bubble keeps the body text on the inverted surface.)

### Success Criteria:

#### Automated Verification:
- [x] Tailwind builds cleanly: `bin/rails tailwindcss:build`
- [x] Test suite green: `bin/rails test`

#### Manual Verification:
- [x] User messages render as right-aligned dark blocks (ink-800) with white text, no visible border, no `user` role label.
- [x] Assistant messages render as left-aligned paper-0 cards with a clearly visible ink-200 border.
- [x] `assistant` role label still visible on the assistant bubble (in `--fg-faint` mono caps).
- [x] Tool-call pills (`🌀 Build started`) still render correctly inside the assistant bubble; the blinking accent dot still animates.
- [x] Build status rows (`✅ Built`, `❌ Build failed: …`) inherit the new assistant surface automatically — paper-0 + stronger border.
- [x] Code blocks / inline code inside assistant bubbles still legible (no token regression).
- [x] Long messages wrap correctly inside both bubble variants; the 80% `max-width` is respected.

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation of the visual before proceeding to Phase 3.

---

## Phase 3: Composer lifts to a paper-0 card

### Commit
`design: composer as paper-0 card matching active tab + assistant bubble`

### Overview
Wrap the composer in its own paper-0 surface so the input area reads as part of the same family as the active tab and the assistant bubble. The `.field-input` becomes borderless inside the composer; the wrapper carries the focus signal.

### Changes Required:

#### 1. `.composer` — turn the layout class into a card
**File**: `app/assets/tailwind/application.css:628-629`
**Change**: Add background, border, padding, radius. Keep `display: flex; gap: 8px;`. Add `:focus-within` for focus.

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

The global `.field-input` block (`application.css:399-420`) is left untouched — these scoped overrides only apply inside `.composer`, so other forms (devise, github_exports) are unaffected.

### Success Criteria:

#### Automated Verification:
- [x] Tailwind builds cleanly: `bin/rails tailwindcss:build`
- [x] Test suite green: `bin/rails test`
- [x] Devise + GitHub-export forms still use the global `.field-input` styling unchanged: `grep -rn 'field-input' app/views/devise app/views/github_exports`

#### Manual Verification:
- [x] At the bottom of `/projects/:id`'s build pane, the composer renders as a paper-0 card with a clearly visible ink-200 border, padding around the contents.
- [x] The text input has no visible border or background fill of its own — the card's frame is the only frame.
- [x] Clicking into the input shifts the *card's* border to accent and shows the focus ring around the card. The input itself shows no separate focus ring.
- [x] The `Send` button (`.btn--primary`) sits inside the card, vertically aligned with the input, unaffected by the change.
- [x] Submitting a message still works (Turbo stream replace, no full-page redirect — see `project_form_replace_over_redirect` memory).
- [x] Devise sign-in / sign-up forms and the GitHub-export form still render their inputs with the original ink-200 border + paper-0 fill (i.e., the global `.field-input` style is unchanged outside the composer).

---

## Testing Strategy

This is a CSS-only change with no logic, no model, and no controller modifications. There are no new branches to unit-test. Verification is primarily visual.

### Manual Testing Steps:
1. **Phase 1 baseline.** `bin/rails server`, sign in, open `/projects/:id` for any existing project. Confirm the three tabs span full width, the active tab reads as a folder card, all switching/keyboard interactions work.
2. **Phase 2 baseline.** Send a message in the studio. Confirm user bubble is dark, assistant bubble is paper-0 + ink-200 border. Trigger a build (any prompt that causes a tool call) and confirm the `🌀 Build started` pill still renders. After build completes, confirm `✅ Built` row renders on the new surface.
3. **Phase 3 baseline.** Click into the composer. Confirm focus signal lives on the wrapper (border + ring on the card, none on the input). Tab out — focus signal clears. Hit Send — message round-trips correctly.
4. **Cross-page regression.** Visit `/`, `/projects/new`, `/projects`, `/users/sign_in`, `/users/sign_up`, the GitHub-export form. Confirm none of these screens have changed visually.
5. **Browser parity.** At minimum repeat steps 1-3 in Safari (the project's dev primary) and Chrome.

## Performance Considerations

None. Pure CSS additions/replacements; no new selectors traverse deeper than two levels; no animations beyond the existing `--dur-fast` transitions.

## Migration Notes

None. No data, schema, or runtime change. All previous projects render under the new styles without any migration step.

## References

- Research: `thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md`
- Origin of current tabs + 1600px shell: `thoughts/shared/plans/2026-05-08/studio-tabs-and-1600-shell.md`
- Typography ramp (already partially shipped): `thoughts/shared/plans/2026-05-09/typography-ramp-bump.md`
- Hifumi canon: `docs/02-architecture/04-design-system.md`
- Tab markup: `app/views/projects/_tab_nav.html.erb:1-33`
- Tab CSS: `app/assets/tailwind/application.css:240-283`
- Tab controller: `app/javascript/controllers/tabs_controller.js:1-60`
- Studio shell: `app/views/projects/show.html.erb:1-60`
- Bubble markup: `app/views/messages/_message.html.erb:1-14`
- Bubble CSS: `app/assets/tailwind/application.css:586-623`
- Status row: `app/views/instructions/_status_row.html.erb:1-16`
- Composer markup: `app/views/messages/_form.html.erb:1-9`
- Composer + field-input CSS: `app/assets/tailwind/application.css:399-420, 628-629`
- Existing inverse surface precedent: `.btn--primary` at `application.css:370`
