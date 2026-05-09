---
date: 2026-05-09T01:37:29+0200
researcher: Paweł Strzałkowski
git_commit: 2dca4d329aa89e8bf5a4c82efb86eac17254f08d
branch: studio-tabs-and-1600-shell
repository: rails-app-generator
topic: "Typography / font-size inventory across all pages and elements"
tags: [research, codebase, typography, hifumi, css, devise, studio, marketing]
status: complete
last_updated: 2026-05-09
last_updated_by: Paweł Strzałkowski
---

# Research: Typography / font-size inventory across all pages and elements

**Date**: 2026-05-09T01:37:29+0200
**Researcher**: Paweł Strzałkowski
**Git Commit**: 2dca4d329aa89e8bf5a4c82efb86eac17254f08d
**Branch**: studio-tabs-and-1600-shell
**Repository**: rails-app-generator

## Research Question

Inventory every font-size in the app — by token, by component class, by page — to support a planned uniform-scale font-size bump. Concrete reference point given: `.project-card__name` resolves to 14px on the projects list, and a target of ~22px is proposed. The signed-out homepage's "large header" should be excluded from the change. Document where each size lives so the bump can be applied consistently.

## Summary

Typography in the app is governed almost entirely by **one file** — `app/assets/tailwind/application.css` — which defines the Hifumi design system's tokens and a closed set of semantic component classes (e.g. `.h-display`, `.h-section`, `.lede`, `.eyebrow`, `.btn`, `.field-input`, `.tag`, `.project-card__name`, `.tab-button__label`, `.pipeline-step__title`, etc.). Templates apply these class names; they do not use Tailwind `text-*` utilities — no `text-xs/sm/base/lg/xl/2xl…` utility appears anywhere in `app/views/`.

There are exactly three places font-size escapes the canonical CSS:

1. **Inline `style="font-size: …px"` in Devise views** — 12 declarations across 5 files (10px-13px range), used for password-hint helper text, OpenRouter API-key notes, the "Remember me" label, `_links.html.erb` wrappers, GitHub-connection paragraphs, and danger-zone explanations.
2. **Embedded `<style>` blocks in `public/*.html` error pages** — 5 static error pages (400, 404, 422, 500, 406) each carry a `font-size: 16px` html base + `clamp(1rem, 2.5vw, 2rem)` body + `font-size: 75%` article scaling. These are Rails-generated defaults, not Hifumi-themed.
3. **`<small>`-style class without a definition** — multiple partials use `class="small"` (e.g. `previews/_starting.html.erb`, `github_exports/_pane.html.erb`, `devise/registrations/new.html.erb`). `.small` is **not defined** in `application.css`. In partials where it appears alone it has no effect (text inherits 16px from `body`); in `registrations/new.html.erb:17` an inline `style="font-size: 11px"` does the actual sizing.

Body text has **no font-size** declared anywhere. The CSS `body` rule (`application.css:110-117`) sets only `background`, `color`, `font-family`, smoothing — it inherits the browser default of **16px**. So any `<p>` / `<div>` / form element without a Hifumi class renders at **16px**. The "feels small" perception is concentrated on classed elements, where the Hifumi scale ranges from **10px (tags, role labels) to 14px (most body classes including `.btn`, `.field-input`, `.project-card__name`, `.pipeline-step__body`)**, with 11px being especially common (`.eyebrow`, `.field-label`, all `__meta`/`__label` slots).

The signed-out homepage hero header is one element: `<h1 class="h-display">` at `app/views/home/index.html.erb:4`. `.h-display` is defined at `application.css:122-129` and is **used nowhere else in the app** — exclusion is structurally clean.

## Detailed Findings

### Source-of-truth file

All Hifumi tokens, semantic types, and component classes that set `font-size` live in a single file:

- `app/assets/tailwind/application.css` (785 lines, `@import "tailwindcss"` then handwritten Hifumi rules)

The compiled output `app/assets/builds/tailwind.css` is generated from this and should not be edited.

There is one other CSS file in `app/assets/`: `app/assets/stylesheets/application.css` is an **empty Sprockets manifest** with no font-size declarations.

### Typography tokens & semantic classes (defined sizes)

All values are taken directly from `app/assets/tailwind/application.css`. Sizes shown in declaration order; line numbers reference the file.

| # | Selector | font-size | Family | Notes | Lines |
|---|---|---|---|---|---|
| 1 | `.h-display` | clamp(36px, 5vw, 60px) | serif | weight 500, lh 1.1, tracking-tight | 122-129 |
| 2 | `.h-section` | 26px | sans | weight 600, lh 1.25, tracking-tight | 131-138 |
| 3 | `.lede` | 20px | serif | weight 400, lh 1.55, fg-muted | 140-146 |
| 4 | `.eyebrow` | 11px | mono | uppercase, tracking-caps | 153-160 |
| 5 | `.app-nav-inner` | 14px | sans | nav container | 197-208 |
| 6 | `.app-nav-brand` | 16px | sans | weight 600 | 211-219 |
| 7 | `.tab-button__numeral` | 28px | (color inherit) | studio-tab kanji glyph | 258-262 |
| 8 | `.tab-button__label` | 11px | mono | uppercase, tracking-caps | 263-270 |
| 9 | `.notice-strip` | 13px | (sans inherit) | flash-strip body | 280-289 |
| 10 | `.notice-strip__tag` | 10px | mono | uppercase, tracking 0.16em | 291-302 |
| 11 | `.notice-strip__body code/pre` | 12px | mono | `<code>` inside flash | 304-311 |
| 12 | `.notice-strip__close` | 14px | mono | the `×` close button | 312-322 |
| 13 | `.btn` | 14px | sans | weight 500, lh 1 | 337-358 |
| 14 | `.btn--sm` | 12px | sans | overrides `.btn` | 377 |
| 15 | `.field-label` | 11px | mono | uppercase, tracking-caps | 382-390 |
| 16 | `.field-input` / `.field-textarea` | 14px | sans | lh 1.5 | 391-405 |
| 17 | `.tag` | 10px | mono | uppercase, tracking 0.14em | 418-433 |
| 18 | `.project-card__name` | 14px | mono | weight 500 — **user's reference point** | 472-482 |
| 19 | `.project-card__meta` | 11px | mono | fg-muted | 484-491 |
| 20 | `.project-card__actions button` | 11px | mono | uppercase, tracking 0.14em | 503-513 |
| 21 | `.revisions__head` | 10px | mono | uppercase, tracking 0.16em | 529-541 |
| 22 | `.revision-row > div` (cell) | 13px | (sans inherit) | base cell | 550-557 |
| 23 | `.revision-row .id` | 11px | mono | tracking 0.04em | 559 |
| 24 | `.revision-row .sha` | 11px | mono | fg-faint | 561 |
| 25 | `.msg-role` | 10px | mono | uppercase, tracking-caps | 590-597 |
| 26 | `.msg-pill` | 12px | mono | tool-call indicator | 599-607 |
| 27 | `.suggestion-chip` | 13px | sans | composer chip | 628-639 |
| 28 | `.preview-pane__header` | 11px | mono | preview frame header | 650-660 |
| 29 | `.preview-pane__empty .small` | 11px | mono | fg-faint | 687-691 |
| 30 | `.preview-pane__error` | 12px | mono | dark code block | 692-701 |
| 31 | `.pipeline-step__numeral` | 56px | serif | weight 500, accent | 758-764 |
| 32 | `.pipeline-step__label` | 11px | mono | uppercase, tracking-caps | 765-771 |
| 33 | `.pipeline-step__title` | 22px | sans | weight 600, tracking-tight | 772-777 |
| 34 | `.pipeline-step__body` | 14px | sans | lh 1.6, fg-muted | 778-783 |

`.mono` (`application.css:148-151`) and `.kanji` (`application.css:168-172`) set font-family/letter-spacing only — they do **not** declare font-size; they ride whatever class they're combined with. `.numeral` (`application.css:162-166`) similarly is family + tabular-numerals only.

`body` (`application.css:110-117`) declares **no font-size** — unclassed text falls back to the browser default of 16px.

### Where unclassed text resolves to 16px

These elements lack any Hifumi class or inline size and therefore render at the browser default 16px:

- `app/views/projects/index.html.erb` empty-state `<p>No projects yet.</p>` and the "Create your first one" link
- `app/views/messages/_message.html.erb` `.msg-body` (the bubble has no size; `.msg-body` only sets `color`/`white-space`/`line-height`)
- `app/views/previews/_stopped.html.erb` and `_starting.html.erb` — `<p>No preview running.</p>` / `<p>Starting preview…</p>` inside `.preview-pane__empty`
- `app/views/previews/_failed.html.erb` `<p>Preview failed.</p>`
- `app/views/github_exports/_pane.html.erb` — `<p>Exporting to GitHub…</p>`, the `<p>` wrappers around `.preview-pane__url` (used outside its header context), `<p style="color:…">Export failed.</p>`, and the `<p class="small">` status messages whose `.small` class has no definition
- `app/views/github_exports/_form.html.erb` — `<label>` (no class), `<input type="text">` (no class), `<input type="checkbox">` (no class). Native `<small>` tag in the same partial renders at the user-agent default (~13px on most browsers)
- `app/views/devise/confirmations/new.html.erb` and `app/views/devise/unlocks/new.html.erb` — fully unstyled default Devise scaffolds; bare `<h2>` (browser default ~24px), unstyled labels and inputs at 16px

### Tailwind text-size utilities

**Zero `text-*` utility classes** are used anywhere in `app/views/`. Confirmed across `layouts/`, `home/`, `projects/`, `instructions/`, `messages/`, `revisions/`, `previews/`, `github_exports/`, `devise/`, `shared/`, `pwa/`. Tailwind utilities present in templates are layout-only (`flex`, `flex-col`, `items-center`, `items-baseline`, `justify-between`, `gap-*`, `w-full`).

This means: no font-size lives in template `class=` attributes via Tailwind. Sizing edits to Hifumi classes are confined to `application.css`.

### Inline `style="font-size: …"` declarations in views

All located inside Devise views; 12 occurrences across 5 files:

- `app/views/devise/passwords/edit.html.erb:13` — `font-size: 12px` (password-requirement helper text)
- `app/views/devise/passwords/edit.html.erb:29` — `font-size: 13px` (links wrapper around `_links.html.erb`)
- `app/views/devise/passwords/new.html.erb:18` — `font-size: 13px` (links wrapper)
- `app/views/devise/sessions/new.html.erb:17` — `font-size: 13px` ("Remember me" label wrapper)
- `app/views/devise/sessions/new.html.erb:28` — `font-size: 13px` (links wrapper)
- `app/views/devise/registrations/new.html.erb:17` — `font-size: 11px` (password minimum hint, on `<p class="small">`)
- `app/views/devise/registrations/new.html.erb:42` — `font-size: 12px` (OpenRouter API-key note)
- `app/views/devise/registrations/new.html.erb:56` — `font-size: 13px` (links wrapper)
- `app/views/devise/registrations/edit.html.erb:29` — `font-size: 12px` (OpenRouter API-key note)
- `app/views/devise/registrations/edit.html.erb:44` — `font-size: 12px` (password-requirement helper)
- `app/views/devise/registrations/edit.html.erb:60` — `font-size: 12px` (current-password helper)
- `app/views/devise/registrations/edit.html.erb:75` — `font-size: 13px` (GitHub-connection status text)
- `app/views/devise/registrations/edit.html.erb:86` — `font-size: 12px` (GitHub-connection helper)
- `app/views/devise/registrations/edit.html.erb:97` — `font-size: 13px` (account-deletion confirmation text)

(Two of the `registrations/edit.html.erb` lines were missed in the initial bullet count — actual count: 14 declarations across the 5 Devise files.)

### Inline `style="font-size: …"` declarations in `public/*.html`

Static Rails error pages — not Hifumi-themed, served outside the app stack:

- `public/400.html`, `public/404.html`, `public/406-unsupported-browser.html`, `public/422.html`, `public/500.html` — each contains in its `<style>`:
  - `html { font-size: 16px }` (line 24)
  - `body { font-size: clamp(1rem, 2.5vw, 2rem) }` (line 32)
  - `article p { font-size: 75% }` (line 105)

### JavaScript / runtime font-size mutations

None. No `fontSize` or `font-size` assignment in any `.js` or `.ts` file in the repo.

### Per-page typography walkthrough

#### Layout (`app/views/layouts/application.html.erb`)

Used by every page (signed-in and signed-out). Body has no font-size (16px browser default). Nav uses `.app-nav-inner` (14px) and `.app-nav-brand` (16px). Flash strips use `.notice-strip` (13px body / 10px tag). The "Sign out" / "Sign up" CTAs are `.btn--sm` (12px).

#### Home / signed-out marketing — `/`, `app/views/home/index.html.erb`

Routed via `config/routes.rb:12` `root "home#index"` to `HomeController#index` (`app/controllers/home_controller.rb:1-5`); when `user_signed_in?` it redirects to `projects_path`, otherwise it renders the home view. No alternate layout — uses `application.html.erb`.

DOM walkthrough of the rendered page:

- nav (from layout) — same as above; signed-out branch shows "Log in" plain link + `.btn.btn--accent.btn--sm` "Sign up"
- `<section class="marketing-shell">` (max-width 1280px)
  - **Hero block** (`.hero`):
    - `<span class="eyebrow">hifumi · 一二三 · hi-fu-mi</span>` — 11px mono
    - `<h1 class="h-display">Build Rails apps from a chat prompt.</h1>` — **clamp(36px, 5vw, 60px) serif** — this is the "large header" the user wants excluded
    - `<p class="lede">…<code class="mono">revisions</code>…</p>` — 20px serif (`.mono` inherits 20px)
    - `<a class="btn btn--accent">Sign up</a>` / `<a class="btn btn--outline">Log in</a>` — 14px sans
  - `<hr class="section-rule">`
  - **Pipeline grid** (`.pipeline`, three `.pipeline-step` cells, identical structure):
    - `.pipeline-step__numeral.kanji` (一 二 三) — 56px serif
    - `.pipeline-step__label` ("hi · 01 · describe", etc.) — 11px mono
    - `.pipeline-step__title` ("You describe the app", etc.) — 22px sans
    - `.pipeline-step__body` (description copy with inline `<code class="mono">`) — 14px sans (the `<code>` inherits 14px)
  - `<hr class="section-rule">`
  - **Closing lede block**:
    - `<p class="lede">Rails Way first…</p>` — 20px serif

`.h-display` is the **only** instance of the display ramp in the entire codebase — verified by inspection of `application.css` and view files.

#### Projects index — `app/views/projects/index.html.erb`

- `<div class="eyebrow">projects · index</div>` — 11px
- `<h1 class="h-section">Your projects</h1>` — 26px
- `<a class="btn btn--primary btn--sm">+ New project</a>` — 12px
- Each project card row:
  - `.project-card__name` — **14px** (user's reference: target ~22px)
  - `.project-card__meta` — 11px (with `.tag.tag--<state>` 10px and `.dot` and "created … ago")
  - `.project-card__actions button` ("delete") — 11px
- Empty state — `<p>No projects yet.</p>` and link inherit 16px (no class, no inline style)

#### Project new — `app/views/projects/new.html.erb`

- `.eyebrow` 11px → `.h-section` 26px → `.notice-strip--err` (if present) 13px / 10px tag → `.field-label` 11px → `.field-textarea` 14px → second `.eyebrow` "starting points" 11px → `.suggestion-chip` 13px → `.btn.btn--primary` "Start" 14px

#### Project show / studio — `app/views/projects/show.html.erb`

- `.eyebrow` "studio · `<span class="mono">project_N</span>`" — 11px (mono span inherits 11px)
- `.h-section` (project name) — 26px
- Shared chat notice (`shared/_chat_notice.html.erb`) — `.notice-strip--err` 13px / 10px tag / 14px `×` close
- Tab nav (`projects/_tab_nav.html.erb`):
  - `.tab-button__numeral.kanji` — 28px serif
  - `.tab-button__label` — 11px mono
- Build pane chat — see message partials below
- Preview pane — see preview partials below
- Export pane — see github-export partials below

##### Studio sub-partials

- `app/views/messages/_form.html.erb` — `.field-input` 14px + `.btn.btn--primary` "Send" 14px
- `app/views/messages/_message.html.erb` — `.msg-role` 10px, `.msg-pill` 12px (when present), `.msg-body` inherits 16px
- `app/views/instructions/_status_row.html.erb` — `.msg-pill` 12px (✅ / ❌ status text)
- `app/views/shared/_chat_notice.html.erb` — `.notice-strip--err` 13px / 10px tag / 14px close

##### Revision partials

- `app/views/revisions/_list.html.erb` — `.revisions__head` 10px
- `app/views/revisions/_revision.html.erb`:
  - `.revision-row .id` 11px mono
  - `.revision-row > div` (summary cell) 13px sans
  - `.revision-row .sha` 11px mono
  - `.tag.tag--<state>` 10px mono

##### Preview partials

All wrap their content in `.preview-pane`:

- `app/views/previews/_stopped.html.erb`, `_starting.html.erb`, `_running.html.erb`, `_failed.html.erb`:
  - `.preview-pane__header` — 11px mono (contains `.eyebrow` 11px + `.tag.tag--<state>` 10px; in `_running` also `.preview-pane__url` inheriting 11px and `.btn.btn--outline.btn--sm` "Stop" 12px)
  - `.preview-pane__empty` body `<p>` — inherits 16px (no class or inline size); `<p class="small">` in `_starting.html.erb` has no `.small` definition, also renders at 16px
  - `.preview-pane__error` (in `_failed.html.erb`) — 12px mono on dark
  - `.btn.btn--accent` action buttons — 14px

##### Export partials

- `app/views/github_exports/_pane.html.erb`:
  - `.preview-pane__header` 11px / `.eyebrow` 11px / `.tag.tag--<state>` 10px
  - Body `<p>` paragraphs — inherit 16px (no class or inline size)
  - `<p class="small">` status messages — `.small` undefined → 16px
  - `<p style="color: var(--err-fg)">Export failed.</p>` — 16px (no font-size in inline style)
  - `.preview-pane__error` (export error log) — 12px mono
  - Buttons — 12px (`btn--sm`) or 14px (`btn`)
- `app/views/github_exports/_form.html.erb` — **the only form in the app that bypasses Hifumi form classes**: bare `<label>`, bare `<input>`, native `<small>` tag (~13px UA default), only the submit `<input class="btn btn--accent btn--sm">` is themed
- `app/views/github_exports/_state_tag.html.erb` — `.tag.tag--<state>` 10px

#### Devise auth pages

All routed under `/users/...`. All use `application.html.erb` layout but with `max-width: 1280px` (tighter than the studio's 1600px).

- `devise/sessions/new.html.erb` (Log in) — `.eyebrow` 11px, `.h-section` 26px (note: `<h2>` not `<h1>`), `.field-label` 11px, `.field-input` 14px, "Remember me" wrapper inline 13px, `.btn.btn--primary` 14px, links wrapper inline 13px
- `devise/registrations/new.html.erb` (Sign up) — `.eyebrow` 11px, `.h-section` 26px, `.notice-strip--err` (errors), `.field-label` 11px, `.field-input/textarea` 14px, password-min hint inline 11px (on `<p class="small">`), OpenRouter-key note inline 12px, `.btn.btn--accent` 14px, links wrapper inline 13px
- `devise/registrations/edit.html.erb` (Edit account) — three sections, all with `.eyebrow` 11px / `.h-section` 26px, multiple inline 12px helper paragraphs, inline 13px GitHub-connection status, inline 13px account-deletion text, `.btn.btn--accent` / `.btn--danger` / `.btn--outline` 14px
- `devise/passwords/new.html.erb` (Forgot password) — `.eyebrow` 11px, `.h-section` 26px, `.field-label` 11px, `.field-input` 14px, `.btn.btn--primary` 14px, links wrapper inline 13px
- `devise/passwords/edit.html.erb` (Reset password) — `.eyebrow` 11px, `.h-section` 26px, `.field-label` 11px, `.field-input` 14px, password-min hint inline 12px, `.btn.btn--primary` 14px, links wrapper inline 13px
- `devise/confirmations/new.html.erb` and `devise/unlocks/new.html.erb` — **unstyled scaffolds**: bare `<h2>` (browser default), plain inputs/labels (16px), no Hifumi classes
- `devise/shared/_links.html.erb` — bare `<a>` links inheriting size from the surrounding inline `font-size: 13px` wrapper; the OmniAuth button (when configured) uses `.btn.btn--outline.btn--sm` (12px)
- `devise/shared/_error_messages.html.erb` — `.notice-strip.notice-strip--err`: 13px body, 10px tag, `<strong>` and `<li>` inherit 13px

#### Mailer layouts

- `app/views/layouts/mailer.html.erb` — empty `<style>` block, no Hifumi classes; the Devise mailer templates (`confirmation_instructions`, `email_changed`, `password_change`, `reset_password_instructions`, `unlock_instructions`) are unmodified Devise scaffolds — outside the visible-chrome scope.

### Frequency / size distribution

Counted across the inventory above (component-class declarations + Devise inline overrides; excludes static error pages and unclassed 16px fall-throughs):

| Resolved size | Class / inline-style instances |
|---|---|
| clamp(36-60) | `.h-display` (1 element on home) |
| 56px | `.pipeline-step__numeral` (3 cells on home) |
| 28px | `.tab-button__numeral` (3 tabs on studio) |
| 26px | `.h-section` (every page title — 9+ pages) |
| 22px | `.pipeline-step__title` (3 cells on home) |
| 20px | `.lede` (2 paragraphs on home) |
| 16px | `.app-nav-brand`; unclassed `<p>` / `<label>` / `<input>` (very common) |
| 14px | `.btn`, `.field-input`, `.field-textarea`, `.app-nav-inner`, `.notice-strip__close`, `.project-card__name`, `.pipeline-step__body` (most "body" content on classed elements) |
| 13px | `.notice-strip`, `.suggestion-chip`, `.revision-row > div`, Devise inline 13px wrappers |
| 12px | `.btn--sm`, `.msg-pill`, `.notice-strip__body code`, `.preview-pane__error`, Devise inline 12px helpers |
| 11px | `.eyebrow`, `.field-label`, `.app-nav-link.active` underline pad, `.tab-button__label`, `.preview-pane__header`, `.preview-pane__empty .small`, `.project-card__meta`, `.project-card__actions button`, `.revision-row .id`, `.revision-row .sha`, `.pipeline-step__label`, Devise password-hint inline 11px |
| 10px | `.tag` (every status pill), `.notice-strip__tag`, `.msg-role`, `.revisions__head` |

The 14px and 11px buckets are the most populated.

### Hifumi anti-patterns / inconsistencies observed

These are documented as state, not flagged for fixing:

- `.small` is referenced as a class in at least three files (`previews/_starting.html.erb`, `github_exports/_pane.html.erb`, `devise/registrations/new.html.erb:17`) but is defined only as a descendant selector `.preview-pane__empty .small` (`application.css:687-691`). Outside that context the class has no effect.
- `app/views/github_exports/_form.html.erb` is the only form in the app that uses bare Rails form helpers (no `.field-label` / `.field-input`) and a native `<small>` element.
- `app/views/devise/confirmations/new.html.erb` and `app/views/devise/unlocks/new.html.erb` are unmodified Devise scaffolds — no Hifumi classes applied.
- Devise inline `font-size` declarations duplicate sizes (12px and 13px) that could equivalently use Hifumi component classes, but the pattern of "inline 12-13px helper text under a form field" is currently consistent across the Devise area.

## Code References

Tokens and component classes:
- `app/assets/tailwind/application.css:9-105` — root tokens (colors, font-family, tracking)
- `app/assets/tailwind/application.css:110-117` — body baseline (no font-size)
- `app/assets/tailwind/application.css:119-172` — semantic type (h-display / h-section / lede / mono / eyebrow / numeral / kanji)
- `app/assets/tailwind/application.css:179-227` — app shell + nav
- `app/assets/tailwind/application.css:229-275` — studio tab nav
- `app/assets/tailwind/application.css:277-332` — flash / notice strip
- `app/assets/tailwind/application.css:334-377` — buttons + `.btn--sm`
- `app/assets/tailwind/application.css:379-413` — forms (`.field-label`, `.field-input`, `.field-textarea`)
- `app/assets/tailwind/application.css:415-450` — status tags + blink
- `app/assets/tailwind/application.css:452-519` — project card
- `app/assets/tailwind/application.css:521-573` — revision list + row
- `app/assets/tailwind/application.css:575-615` — chat bubbles + msg-role + msg-pill
- `app/assets/tailwind/application.css:617-639` — composer + suggestion chips
- `app/assets/tailwind/application.css:641-708` — preview pane (header, empty, error, frame)
- `app/assets/tailwind/application.css:710-783` — home / marketing pipeline

Pages:
- `app/views/layouts/application.html.erb` — global layout, nav, flash
- `app/views/home/index.html.erb:4` — `.h-display` hero header (the "large" element to exclude)
- `app/views/home/index.html.erb:18-49` — pipeline grid
- `app/views/projects/index.html.erb` — projects list (cards)
- `app/views/projects/new.html.erb` — describe-app form
- `app/views/projects/show.html.erb` — studio (build/preview/export tabs)
- `app/views/projects/_tab_nav.html.erb` — studio tab buttons
- `app/views/messages/_form.html.erb`, `_message.html.erb` — chat composer + bubbles
- `app/views/instructions/_status_row.html.erb` — built/failed pill
- `app/views/revisions/_list.html.erb`, `_revision.html.erb` — revision list
- `app/views/previews/_stopped.html.erb`, `_starting.html.erb`, `_running.html.erb`, `_failed.html.erb` — preview pane states
- `app/views/github_exports/_pane.html.erb`, `_form.html.erb`, `_state_tag.html.erb` — GitHub export
- `app/views/shared/_chat_notice.html.erb` — chat error strip
- `app/views/devise/sessions/new.html.erb` — log in
- `app/views/devise/registrations/new.html.erb` — sign up
- `app/views/devise/registrations/edit.html.erb` — account edit (three sections)
- `app/views/devise/passwords/new.html.erb`, `edit.html.erb` — forgot/reset password
- `app/views/devise/confirmations/new.html.erb`, `unlocks/new.html.erb` — unstyled scaffolds
- `app/views/devise/shared/_links.html.erb`, `_error_messages.html.erb` — Devise shared partials
- `public/400.html`, `404.html`, `406-unsupported-browser.html`, `422.html`, `500.html` — static error pages

Routing of the home page:
- `config/routes.rb:12` — `root "home#index"`
- `app/controllers/home_controller.rb:1-5` — `HomeController#index` with signed-in redirect

## Architecture Documentation

The Hifumi design system applied 2026-05-01 follows a single-file convention: tokens (CSS custom properties) and a closed set of semantic component classes live together in `app/assets/tailwind/application.css`. Templates apply Hifumi class names (e.g. `h-section`, `field-input`, `tag tag--ok`) and Tailwind layout utilities (e.g. `flex`, `gap-4`, `w-full`); they do **not** use Tailwind typography utilities. This means the typography ramp is centralized in one file and discoverable by reading top-to-bottom.

Sizing is expressed in absolute `px` values throughout. The only relative/responsive sizing is `clamp(36px, 5vw, 60px)` on `.h-display` (the marketing hero). Body text has no declared font-size and inherits the browser default of 16px; this means an unclassed `<p>` is larger than every "body-class" target like `.btn` (14px) or `.notice-strip` (13px).

The signed-out homepage and the authenticated app share the same `application.html.erb` layout — there is no separate marketing layout. The "large header" exclusion the user described corresponds to a single class (`.h-display`) used at exactly one site (`app/views/home/index.html.erb:4`). The hero CTAs (`.btn`) and the subsidiary `.lede`, `.eyebrow`, `.pipeline-step__*` classes are shared with chrome that appears across all pages or are marketing-only ramps that nonetheless use the global token palette.

Devise pages deviate from the rest of the app by using inline `style="font-size: …"` for helper text and link wrappers (12-13px range, plus one 11px), whereas the studio area uses dedicated component classes for analogous slots. The undefined `.small` class appears in three files as a leftover marker.

## Historical Context (from thoughts/)

- `thoughts/shared/research/2026-05-02/design-systems-randomized-application.md` — context for the Hifumi system selection process (it was randomized from a candidate set on 2026-05-01).
- `thoughts/shared/research/2026-05-08/authenticated-screens-layout-and-project-show-tabs.md` — recent inventory of the authenticated shell that fed into the current `studio-tabs-and-1600-shell` branch (commits `c25e8e0`, `4b7e470`, `b3d7b7c`, `2dca4d3`).
- `thoughts/shared/research/2026-05-08/users-edit-unstyled.md` — prior research that surfaced the unstyled Devise pages noted above.
- `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md` — plan addressing the partially-unstyled Devise scaffolds.

## Related Research

- `thoughts/shared/research/2026-05-02/design-systems-randomized-application.md`
- `thoughts/shared/research/2026-05-08/authenticated-screens-layout-and-project-show-tabs.md`
- `thoughts/shared/research/2026-05-08/users-edit-unstyled.md`

## Open Questions

These are decisions the user would need to make to apply the proposed font-size bump (~+8px / ~1.57x at the 14→22px reference point):

1. Is the desired transformation a **uniform multiplier** (e.g. `×1.57`) or a **uniform delta** (e.g. `+8px`)? The two diverge sharply at the small end: 10px → 16px (delta) vs 10px → 16px (multiplier ≈ 15.7px) — close at this size, but at the large end 56px → 64px (delta) vs 88px (multiplier).
2. Should the **16px browser-default fallback** (unclassed `<p>` / `<label>` / Devise scaffold text) also move? It's not a token in `application.css`, so any change requires either adding a `body { font-size: … }` rule or classing those elements. They currently render visually similar to or slightly larger than the 14px-classed body slots.
3. Should the **Devise inline `font-size: …` declarations** (14 occurrences across 5 files) be replaced with the same multiplier/delta, or be migrated to Hifumi classes (e.g. a shared `.helper-note` at the new size) as part of the bump?
4. Should the **`<small>` element** in `app/views/github_exports/_form.html.erb` and the undefined `.small` class usages be normalized first, or left as-is and addressed separately?
5. Are there typography slots that should be bumped **less aggressively** because they appear in dense list contexts (e.g. `.tag` 10px, `.msg-role` 10px, `.notice-strip__tag` 10px, `.revisions__head` 10px) where doubling could break grid `grid-template-columns: 4px 56px 110px 1fr 90px` in `.revision-row`?
6. Should `.h-display` (the home hero) and `.h-section` (every page title) move proportionally with the rest, or should the **already-large** sizes (`.h-display` 36-60, `.pipeline-step__numeral` 56, `.tab-button__numeral` 28, `.h-section` 26, `.pipeline-step__title` 22, `.lede` 20) be capped/excluded? The user named only the home hero as exempt.
7. Should `public/*.html` static error pages be touched, or are they out-of-scope (they are not Hifumi-themed)?
