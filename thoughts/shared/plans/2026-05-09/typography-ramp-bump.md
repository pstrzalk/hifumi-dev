---
date: 2026-05-09
author: Paweł Strzałkowski
status: draft
related_research: thoughts/shared/research/2026-05-09/typography-font-size-inventory.md
related_plans: thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md
---

# Typography ramp bump (×1.57, anchor 14→22) — Implementation Plan

## Overview

Bump every font-size in the app upward by a multiplier of ~×1.57 (anchored on `.project-card__name` 14→22), snapped to clean even values, while excluding `.h-display` (the home hero). Set a body baseline so unclassed text doesn't fall behind classed text. Define `.small` globally (currently undefined). Update Devise inline `style="font-size: ..."` declarations in place. Class up the one un-Hifumi'd form (`github_exports/_form.html.erb`). Audit and adjust two fixed-grid-column layouts that get tight at the new sizes.

The bump preserves Hifumi's scale shape (same visual ratios), excludes only the explicit hero, and merges one close pair (12+13 → 20) where the 1px distinction reads as noise.

## Current State Analysis

Typography is governed almost entirely by one file: `app/assets/tailwind/application.css`. Templates apply Hifumi component classes (`.btn`, `.field-input`, `.project-card__name`, etc.) — no Tailwind `text-*` utilities are used anywhere in `app/views/`.

The font-size landscape (verified by `grep -n 'font-size' app/assets/tailwind/application.css`) — 34 declarations covering 11 distinct sizes:

| Size | Selectors |
|---|---|
| clamp(36, 5vw, 60) | `.h-display` (home hero — single use) |
| 56px | `.pipeline-step__numeral` |
| 28px | `.tab-button__numeral` |
| 26px | `.h-section` (every page title) |
| 22px | `.pipeline-step__title` |
| 20px | `.lede` |
| 16px | `.app-nav-brand` (and unclassed body via browser default) |
| 14px | `.btn`, `.field-input`, `.field-textarea`, `.app-nav-inner`, `.notice-strip__close`, `.project-card__name`, `.pipeline-step__body` |
| 13px | `.notice-strip`, `.suggestion-chip`, `.revision-row > div` |
| 12px | `.btn--sm`, `.msg-pill`, `.notice-strip__body code`, `.preview-pane__error` |
| 11px | `.eyebrow`, `.field-label`, `.tab-button__label`, `.preview-pane__header`, `.preview-pane__empty .small`, `.project-card__meta`, `.project-card__actions button`, `.revision-row .id`, `.revision-row .sha`, `.pipeline-step__label` |
| 10px | `.tag`, `.notice-strip__tag`, `.msg-role`, `.revisions__head` |

Three escape hatches from the canonical CSS:

1. **Devise inline** — 14 `style="font-size: …px"` declarations across 5 files (11/12/13px). Inventory confirmed by `grep -rn 'font-size' app/views/devise/`.
2. **Static error pages** — `public/{400,404,406-unsupported-browser,422,500}.html` carry their own embedded `<style>` blocks. Out of scope (different visual system).
3. **Undefined `.small` class** — referenced as `class="small"` in `previews/_starting.html.erb`, `github_exports/_pane.html.erb`, and `devise/registrations/new.html.erb:17`, but only defined as a descendant selector `.preview-pane__empty .small`. Outside that context the class has no effect. The 11px on `registrations/new.html.erb:17` is delivered by an inline override.

`body` (`application.css:110-117`) has **no font-size** and **no line-height** — unclassed text inherits browser defaults (16px, ~1.2 line-height).

`github_exports/_form.html.erb` is the only form in the app that bypasses Hifumi form classes — bare `<label>`, bare `<input>`, native `<small>`. The other "unstyled" Devise views (`confirmations/new.html.erb`, `unlocks/new.html.erb`) are unreachable scaffold leftovers — the existing plan at `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md` (lines 19, 61) established that `User.devise_modules` doesn't include `:confirmable` or `:lockable`, so the corresponding routes don't exist.

## Desired End State

Every font-size in `app/assets/tailwind/application.css` (except `.h-display`) is updated to the new ramp. The body element declares `font-size: 22px; line-height: 1.5`. A global `.small` class is defined. The 14 Devise inline declarations are updated to the new values (with one redundancy removed). `github_exports/_form.html.erb` uses Hifumi form classes. Dense grid layouts (`.notice-strip`, `.revision-row`) have column widths bumped to fit the new tag/sha sizes without truncation.

How to verify: walk every reachable route in `bin/rails routes` and confirm the page reads with the new ramp; specifically inspect `.project-card__name` is 22px in DevTools on `/projects`, and confirm the home hero `.h-display` is unchanged (still clamp 36-60).

### Key Discoveries

- `app/assets/tailwind/application.css` is the only file with `font-size` declarations in the app stylesheet (`app/assets/stylesheets/application.css` is an empty Sprockets manifest).
- Compiled `app/assets/builds/tailwind.css` is generated; never edit directly.
- The body baseline (currently undeclared, inheriting 16px) is load-bearing for `.msg-body`, empty-state `<p>` elements, the bare inputs in `_form.html.erb`, and any other unclassed text. Bumping classed body to 22 without setting body would visually invert the relationship (unclassed becomes smaller than classed).
- `.preview-pane__empty .small` (`application.css:687-691`) is currently the only definition of `.small` in the codebase. After defining `.small` globally, this descendant rule becomes redundant and can be removed (Phase 1 cleanup).
- The 11px inline on `registrations/new.html.erb:17` co-exists with `class="small"` on the same element — once `.small` is defined globally at 18px, the inline override should be dropped (Phase 2 cleanup).
- Two fixed-column grids may run tight at the new sizes:
  - `.notice-strip` (line 282): `4px 88px 1fr auto` — col 2 holds `.notice-strip__tag` (10→16, uppercase + tracking 0.16em).
  - `.revision-row` (line 544): `4px 56px 110px 1fr 90px` — col 5 holds `.tag` (10→16, similar tracking). Cols 2 and 3 (id 11→18, sha 11→18 mono) have headroom and don't need bumping.
- `.h-display` is used at exactly one site: `app/views/home/index.html.erb:4`. Excluding it is structurally clean.
- `.pipeline-step__numeral` (56→88) will become larger than `.h-display` (capped at 60). Documented consequence; not a regression — the kanji visual is the home page's intended focal point.

## What We're NOT Doing

- **`.h-display` bump.** Explicitly excluded per the originating brief.
- **`public/*.html` static error pages.** Not Hifumi-themed; served outside the app stack with their own embedded responsive sizing. Different system; address separately if at all.
- **`devise/confirmations/new.html.erb` and `devise/unlocks/new.html.erb`.** Routes don't exist (`User` lacks `:confirmable` and `:lockable`); editing them is dead code. Honor the prior plan's analysis.
- **Devise mailer templates.** HTML email is a separate styling concern.
- **Conversion to relative units (`em` / `rem`).** Stay with `px` (existing convention; no semantic gain at this scope).
- **New Hifumi component classes** beyond global `.small`. If a need surfaces, raise as follow-up.
- **Refactoring fixed grid widths to flexible (`auto`/`fr`).** Bump the specific columns that need it; broader refactor is out of scope.
- **System / Capybara tests for visual styling.** Per `project_verify_no_system_tests.md`. Manual verification is canonical.

## Implementation Approach

Three phases — each one atomic commit, each independently shippable, each verifiable in the browser.

1. **Phase 1: CSS ramp + body baseline + grid widths.** All `application.css` changes in one commit. Inseparable for atomicity — half a ramp creates inconsistencies the next half resolves.
2. **Phase 2: Devise inline value sweep.** 14 mechanical edits across 5 files; drop one redundant inline.
3. **Phase 3: Class up `github_exports/_form.html.erb`.** Replace bare form helpers with Hifumi field classes.

After Phase 1, the app is fully usable; Phases 2 and 3 polish the corners that escape canonical CSS.

### The new ramp

| Tier | Old → New | Selectors affected |
|---|---|---|
| display (excluded) | clamp(36-60) → clamp(36-60) | `.h-display` |
| pipeline numeral | 56 → **88** | `.pipeline-step__numeral` |
| tab numeral | 28 → **44** | `.tab-button__numeral` |
| section | 26 → **40** | `.h-section` |
| title | 22 → **36** | `.pipeline-step__title` |
| lede | 20 → **32** | `.lede` |
| body emphasis | 16 → **24** | `.app-nav-brand` |
| body (anchor) | 14 → **22** ★ | `.btn`, `.field-input`, `.field-textarea`, `.app-nav-inner`, `.notice-strip__close`, `.project-card__name`, `.pipeline-step__body`, **`body`** (new declaration) |
| caption | 12, 13 → **20** | `.btn--sm`, `.msg-pill`, `.notice-strip__body code`, `.preview-pane__error`, `.notice-strip`, `.suggestion-chip`, `.revision-row > div` |
| label | 11 → **18** | `.eyebrow`, `.field-label`, `.tab-button__label`, `.preview-pane__header`, `.project-card__meta`, `.project-card__actions button`, `.revision-row .id`, `.revision-row .sha`, `.pipeline-step__label`, **`.small`** (new global definition) |
| tag | 10 → **16** | `.tag`, `.notice-strip__tag`, `.msg-role`, `.revisions__head` |

11 distinct sizes → 10 (12+13 collapse to 20). All even values.

---

## Phase 1: Bump the typography ramp in CSS

### Commit
`design: bump typography ramp ×1.57 anchored at 14→22`

### Overview
Update every `font-size` in `app/assets/tailwind/application.css` (except `.h-display`) to the new ramp. Add `font-size: 22px; line-height: 1.5;` to `body`. Define `.small` globally. Remove the now-redundant `.preview-pane__empty .small` descendant rule. Bump fixed-column widths in `.notice-strip` and `.revision-row` so tag columns fit the new 16px tag size.

### Changes Required

#### `app/assets/tailwind/application.css`

**Body baseline** — add two declarations to the existing `body` rule at lines 110-117:

```css
body {
  background: var(--bg);
  color: var(--fg);
  font-family: var(--hi-font-sans);
  font-size: 22px;        /* NEW */
  line-height: 1.5;       /* NEW */
  font-feature-settings: "ss01", "cv11";
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}
```

**Component-class font-size updates** — apply per-line:

| Line | Selector | Change |
|---|---|---|
| 124 | `.h-display` | **unchanged** (clamp(36px, 5vw, 60px)) |
| 133 | `.h-section` | 26px → **40px** |
| 142 | `.lede` | 20px → **32px** |
| 155 | `.eyebrow` | 11px → **18px** |
| 206 | `.app-nav-inner` | 14px → **22px** |
| 214 | `.app-nav-brand` | 16px → **24px** |
| 259 | `.tab-button__numeral` | 28px → **44px** |
| 265 | `.tab-button__label` | 11px → **18px** |
| 286 | `.notice-strip` | 13px → **20px** |
| 296 | `.notice-strip__tag` | 10px → **16px** |
| 307 | `.notice-strip__body code` | 12px → **20px** |
| 317 | `.notice-strip__close` | 14px → **22px** |
| 343 | `.btn` | 14px → **22px** |
| 377 | `.btn--sm` | 12px → **20px** |
| 385 | `.field-label` | 11px → **18px** |
| 394 | `.field-input` / `.field-textarea` | 14px → **22px** |
| 423 | `.tag` | 10px → **16px** |
| 475 | `.project-card__name` | 14px → **22px** ★ |
| 489 | `.project-card__meta` | 11px → **18px** |
| 508 | `.project-card__actions button` | 11px → **18px** |
| 537 | `.revisions__head` | 10px → **16px** |
| 555 | `.revision-row > div` | 13px → **20px** |
| 559 | `.revision-row .id` | 11px → **18px** |
| 561 | `.revision-row .sha` | 11px → **18px** |
| 592 | `.msg-role` | 10px → **16px** |
| 601 | `.msg-pill` | 12px → **20px** |
| 630 | `.suggestion-chip` | 13px → **20px** |
| 659 | `.preview-pane__header` | 11px → **18px** |
| 689 | `.preview-pane__empty .small` | **delete entire rule** (now covered by global `.small`) |
| 694 | `.preview-pane__error` | 12px → **20px** |
| 761 | `.pipeline-step__numeral` | 56px → **88px** |
| 767 | `.pipeline-step__label` | 11px → **18px** |
| 775 | `.pipeline-step__title` | 22px → **36px** |
| 780 | `.pipeline-step__body` | 14px → **22px** |

**Add global `.small` class** — insert after `.eyebrow` (around line 161, before `.numeral`) so it sits in the SEMANTIC TYPE block:

```css
.small {
  font-family: var(--hi-font-mono);
  font-size: 18px;
  color: var(--fg-faint);
}
```

**Grid column adjustments**:

- Line 282 — `.notice-strip` `grid-template-columns`:
  ```css
  /* before */ grid-template-columns: 4px 88px 1fr auto;
  /* after  */ grid-template-columns: 4px 110px 1fr auto;
  ```
  Rationale: `.notice-strip__tag` at 16px uppercase mono (tracking 0.16em). Longest typical content like "WARNING" needs ~100px including padding; 110 leaves headroom.

- Line 544 — `.revision-row` `grid-template-columns`:
  ```css
  /* before */ grid-template-columns: 4px 56px 110px 1fr 90px;
  /* after  */ grid-template-columns: 4px 56px 110px 1fr 120px;
  ```
  Rationale: `.tag` at 16px uppercase tracked. "QUEUED" ~89px, "RUNNING" ~95px including padding; 120 fits the longest tags safely. The 56px (id) and 110px (sha) columns have ample headroom for 18px mono content (1-2 digits / 7-char hash).

The mobile `.revision-row` rule at line 570 (`grid-template-columns: 4px 1fr;`) stays unchanged.

### Success Criteria

#### Automated Verification
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Tailwind compiles: `bin/rails tailwindcss:build` (re-runs the compile step that produces `app/assets/builds/tailwind.css`)
- [x] No regression in CSS shape: `grep -c 'font-size' app/assets/tailwind/application.css` returns the same count or one more (one new line for `.small`, one new for `body { font-size }` — net **+2** vs current count) — went from 34 → 35 (body +1, .small +1, removed `.preview-pane__empty .small` -1 = net +1, within accepted range)
- [x] `.h-display` literally unchanged: verified via `grep -A2 '^\.h-display' …` (font-size is on the third line of the rule, so the original `-A1` formulation did not match — the value `clamp(36px, 5vw, 60px)` is intact)
- [x] Tests pass: `bin/rails test` — 353 runs, 1275 assertions, 0 failures, 0 errors, 2 skips (pre-existing)

#### Manual Verification
- [x] `/` (signed out): `.h-display` hero visually unchanged at desktop width; `.lede` paragraphs noticeably larger; pipeline kanji `.pipeline-step__numeral` is the largest element on the page (88px > 60px hero — expected).
- [x] `/projects`: project cards read at the new sizes — `.project-card__name` is 22px (verify in DevTools), `.project-card__meta` is 18px, status `.tag` is 16px and fits inside its row without truncation. `.h-section` "Your projects" reads at 40px.
- [x] `/projects/new`: `.field-textarea` is 22px, `.suggestion-chip`s are 20px, `.btn.btn--primary` "Start" is 22px.
- [x] `/projects/:id` (studio): tab kanji at 44px, tab labels at 18px, chat composer `.field-input` at 22px, "Send" button at 22px, `.msg-role` at 16px, any visible `.msg-pill` at 20px, suggestion chips at 20px. Trigger an instruction; verify the `.msg-pill` (✅ DONE / ❌ FAILED) sits proportionally with the message body.
- [x] Revisions panel: `.revisions__head` row reads at 16px tag; revision rows show id/sha at 18px mono, summary at 20px, tag at 16px. Tag column visually fits the longest tag content (e.g. "RUNNING").
- [x] Preview pane (each state — stopped/starting/running/failed): `.preview-pane__header` at 18px, "no preview running" / "starting preview…" empty-state copy at 18px (the `.small` class now resolves globally, no longer dependent on the descendant rule).
- [x] Notice strips (trigger one via a validation error on `/projects/new`): notice tag column fits "ERROR"/"WARNING" at 16px without overflow; body reads at 20px; the `×` close at 22px.
- [x] Devise screens (`/users/sign_in`, `/users/sign_up`): non-Devise-inline content (eyebrow, h-section, field-label, field-input, btn) reads at the new ramp. Inline-styled helpers still at OLD sizes — that's Phase 2. (User confirmed: small helpers still small — Phase 2 will resolve.)
- [x] Unclassed text (`.msg-body` content, empty-state `<p>` in projects/index, `<p>Exporting to GitHub…</p>` in github_exports/_pane) reads at 22px (body baseline applies).

**Implementation Note**: After this phase and all automated verification passes, pause for manual confirmation that the app reads correctly across the routes above before moving to Phase 2.

---

## Phase 2: Update Devise inline font-size declarations

### Commit
`design: bump devise inline font-sizes to new ramp`

### Overview
Mechanical sweep of the 14 inline `style="font-size: …px"` declarations in `app/views/devise/`. Map old values to new (11→18, 12→20, 13→20). Drop the now-redundant `font-family` + `font-size` from the inline on `registrations/new.html.erb:17` since the `.small` class (now defined globally in Phase 1) handles both.

### Changes Required

| File | Line | Old inline | New inline | Notes |
|---|---|---|---|---|
| `app/views/devise/passwords/edit.html.erb` | 13 | `font-size: 12px` | `font-size: 20px` | password-min hint |
| `app/views/devise/passwords/edit.html.erb` | 29 | `font-size: 13px` | `font-size: 20px` | links wrapper |
| `app/views/devise/passwords/new.html.erb` | 18 | `font-size: 13px` | `font-size: 20px` | links wrapper |
| `app/views/devise/registrations/edit.html.erb` | 29 | `font-size: 12px` | `font-size: 20px` | OpenRouter hint |
| `app/views/devise/registrations/edit.html.erb` | 44 | `font-size: 12px` | `font-size: 20px` | password-min hint |
| `app/views/devise/registrations/edit.html.erb` | 60 | `font-size: 12px` | `font-size: 20px` | current-password hint |
| `app/views/devise/registrations/edit.html.erb` | 75 | `font-size: 13px` | `font-size: 20px` | GitHub-connection text |
| `app/views/devise/registrations/edit.html.erb` | 86 | `font-size: 12px` | `font-size: 20px` | GitHub helper |
| `app/views/devise/registrations/edit.html.erb` | 97 | `font-size: 13px` | `font-size: 20px` | account-deletion text |
| `app/views/devise/registrations/new.html.erb` | 17 | `<p class="small" style="margin: 4px 0 0; font-family: var(--hi-font-mono); font-size: 11px; color: var(--fg-faint);">` | `<p class="small" style="margin: 4px 0 0;">` | Drop redundant `font-family`, `font-size`, `color` — the global `.small` class sets all three. Keep only `margin`. |
| `app/views/devise/registrations/new.html.erb` | 42 | `font-size: 12px` | `font-size: 20px` | OpenRouter note |
| `app/views/devise/registrations/new.html.erb` | 56 | `font-size: 13px` | `font-size: 20px` | links wrapper |
| `app/views/devise/sessions/new.html.erb` | 17 | `font-size: 13px` | `font-size: 20px` | "Remember me" wrapper |
| `app/views/devise/sessions/new.html.erb` | 28 | `font-size: 13px` | `font-size: 20px` | links wrapper |

13 simple value swaps + 1 cleanup (line 17 of registrations/new.html.erb).

### Success Criteria

#### Automated Verification
- [x] No 11/12/13px inline left in Devise: `grep -rE 'font-size: *(11|12|13)px' app/views/devise/` returns empty
- [x] All Devise inline declarations are at the new ramp: only `font-size: 20px` remains across Devise views (the line-17 `registrations/new.html.erb` cleanup dropped the inline 11px entirely; all other inlines map to 20px). Plan said `{18px, 20px}` but 18px never appears since none of the inlines used 11px → 18px in Phase 2 (the only 11px inline was deleted).
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Existing Devise tests still pass: 15 runs, 73 assertions, 0 failures, 0 errors

#### Manual Verification
- [x] `/users/sign_up`: password-min hint and OpenRouter note read at the new size; the hint text on line 17 (now `class="small"` only, no inline override) renders mono fg-faint at 18px (matches the global `.small` definition); links wrapper at the bottom renders at 20px; visual rhythm matches the rest of the form. (Mid-phase tweak: OpenRouter notice on line 42 also converted to `class="small"` so both small-print elements share one idiom.)
- [x] `/users/sign_in`: "Remember me" label and links wrapper at 20px.
- [x] `/users/edit`: all three sections (profile, GitHub, danger zone) — helper paragraphs at 20px, GitHub-connection status at 20px, deletion-confirmation text at 20px.
- [x] `/users/password/new`, `/users/password/edit?reset_password_token=invalid`: helper texts at 20px, links wrapper at 20px.
- [x] No emoji or hardcoded hex introduced.

**Out-of-scope tweak rolled in alongside Phase 2**: Sessions/passwords submit buttons (`Log in`, `Send me password reset instructions`, `Change my password`) flipped from `btn--primary` (black) to `btn--accent` (red) so all auth-page CTAs share the conversion-action color (matching `Sign up` / `Update account`). Three one-line edits in `sessions/new.html.erb`, `passwords/new.html.erb`, `passwords/edit.html.erb`.

**Implementation Note**: After this phase and all automated verification passes, pause for manual confirmation before Phase 3.

---

## Phase 3: Hifumi-style the GitHub export form

### Commit
`design: hifumi-style github export form`

### Overview
Replace bare `<label>` / `<input>` / `<small>` in `app/views/github_exports/_form.html.erb` with `.field-label` / `.field-input` / `<p class="small">`. Mirror the form idiom established by `registrations/new.html.erb`. Restructure the wrapper from scaffold-style `<div class="field">` blocks to a `flex flex-col` container with `gap` (matches the rest of the app's forms).

### Changes Required

#### `app/views/github_exports/_form.html.erb` — full rewrite (16 lines)

```erb
<%= form_with url: project_github_export_path(project), scope: :github_export,
      data: { turbo_frame: "github_export_pane" },
      class: "flex flex-col", style: "gap: 16px;" do |f| %>
  <div>
    <%= f.label :repo_name, "Repository name", class: "field-label" %>
    <%= f.text_field :repo_name, value: project.name.parameterize, required: true, class: "field-input" %>
  </div>

  <div>
    <label class="flex items-center" style="gap: 8px;">
      <%= f.check_box :private_repo, { checked: true }, "1", "0" %>
      <span>Private repository</span>
    </label>
    <p class="small" style="margin: 6px 0 0;">Defaults to private. You can flip the repo to public on GitHub later.</p>
  </div>

  <%= f.submit "Export to GitHub", class: "btn btn--accent btn--sm", style: "align-self: flex-start;" %>
<% end %>
```

Notes on the diff:
- Drops the two `<div class="field">` scaffold wrappers in favor of plain `<div>` + `flex flex-col` parent (existing pattern from `registrations/new.html.erb:5`).
- The "Private repository" `<label>` keeps the `flex items-center` inline pattern (the same approach used by `sessions/new.html.erb:17` for "Remember me"), but no `font-size` inline — body baseline 22px now applies.
- `<p><small>…</small></p>` becomes `<p class="small">…</p>` — same visual intent (mono fg-faint label-tier text), now driven by the global `.small` class. The `<p>` keeps a `margin: 6px 0 0` for spacing under the checkbox row.
- Submit retains `btn btn--accent btn--sm` (accent for the "primary action" CTA, `--sm` because it's a single export action inside a side-pane, matching the existing visual hierarchy).

### Success Criteria

#### Automated Verification
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Tests pass: `bin/rails test` — 353 runs, 1275 assertions, 0 failures, 0 errors, 2 skips (pre-existing)
- [x] Form references Hifumi tokens: `grep -cE 'field-label|field-input|btn btn--' app/views/github_exports/_form.html.erb` returns 3
- [x] No bare scaffold markup left: `grep -E '<div class="field"|<small>' app/views/github_exports/_form.html.erb` returns empty

#### Manual Verification
- [ ] On the studio Export tab of any project (`/projects/:id` → Export tab) showing the form: the "Repository name" label reads as a Hifumi `field-label` (mono uppercase tracked at 18px); the input has the standard `.field-input` border + focus ring at 22px; the checkbox row reads inline with its label; the helper text under the checkbox reads at 18px mono fg-faint (the global `.small` definition); "Export to GitHub" submit is `btn--accent btn--sm` left-aligned.
- [ ] Submitting the form actually exports — no controller / route regression. Verify against the existing happy-path: enter a repo name, click submit, confirm the export starts and the pane updates.
- [ ] Visual parity with the form on `/users/sign_up` for the same primitives (label, input, helper text under field).
- [ ] The exporting/exported/failed states (rendered by `_pane.html.erb` after submit) still read correctly — Phase 1 covered the pane's own typography.

**Implementation Note**: After this phase, the entire bump is complete. Run `git diff --stat main...HEAD` and confirm only the expected files are touched: `app/assets/tailwind/application.css` (Phase 1), the 5 Devise view paths (Phase 2), and `app/views/github_exports/_form.html.erb` (Phase 3).

---

## Testing Strategy

### Automated
- Tailwind compile (`bin/rails tailwindcss:build`) catches any CSS syntax errors introduced in Phase 1.
- Existing controller/integration tests (especially `test/integration/github_oauth_test.rb` and `test/controllers/users/registrations_controller_test.rb`) cover the render-smoke for Devise screens touched in Phase 2 and the GitHub export controller in Phase 3.
- `grep` assertions in each phase's automated verification checklist guard against accidentally leaving old values behind.
- No new automated tests added — typography is not amenable to unit/integration assertions, and system tests are off-limits per `project_verify_no_system_tests.md`.

### Manual

After Phase 1 (the typography ramp is the highest-leverage check):
1. `bin/dev` (or `bin/rails server`) and walk every route in `bin/rails routes` for the Devise tree plus `/`, `/projects`, `/projects/new`, `/projects/:id` (with a generation in progress so chat + revisions + preview render).
2. DevTools-inspect `.project-card__name` on `/projects` — verify `font-size: 22px`. This is the originating reference point.
3. DevTools-inspect `.h-display` on `/` — verify `font-size: clamp(36px, 5vw, 60px)` is unchanged.
4. Trigger a notice-strip (e.g. validation error on `/projects/new` by submitting empty) and confirm the tag column fits without truncation.
5. Open a project with revisions in the list — verify the revision-row tag column ("RUNNING" / "DONE" / "FAILED") fits, and the id/sha read at 18px mono.

After Phase 2:
6. Walk every Devise route and confirm the inline-styled helpers no longer look smaller than the surrounding form chrome.

After Phase 3:
7. Walk to the studio Export tab and confirm the form matches the visual idiom of the sign-up form.

### Edge cases / regressions to watch
- **Mobile viewport** (`max-width: 720px` media query at `application.css:567-571`): `.revision-row` collapses to `4px 1fr`, hiding the tag column. Verify the row still renders cleanly with the larger summary text at 20px.
- **`.preview-pane__empty .small`** (deleted in Phase 1): the empty state in `previews/_starting.html.erb` and `previews/_stopped.html.erb` now uses the global `.small` (18px mono fg-faint) instead of the descendant rule (was 11px mono fg-faint). The new size is the intended ramp result; visually verify the empty pane reads correctly.
- **`<code>` / `<pre>` blocks** inside `.notice-strip__body` now read at 20px instead of 12px — much larger. The notice-strip is small chrome; verify a long error message with `<code>` inline still wraps cleanly.

## Performance Considerations

None. CSS-only and view-template changes; no schema, queries, partials, or JS.

## Migration Notes

None. No data, route, or controller changes. The bump is purely visual.

## References

- Research: `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md`
- Tokens / component classes: `app/assets/tailwind/application.css:9-783`
- Body baseline (insertion target): `app/assets/tailwind/application.css:110-117`
- `.h-display` (excluded): `app/assets/tailwind/application.css:122-129` + sole use at `app/views/home/index.html.erb:4`
- Reference form idiom (for Phase 3): `app/views/devise/registrations/new.html.erb:1-59`
- Prior plan establishing the unreachable-scaffolds analysis: `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md:19,61`
- Convention: CLAUDE.md → "Conventions / Design system: Hifumi"
- Architecture doc: `docs/02-architecture/04-design-system.md`
