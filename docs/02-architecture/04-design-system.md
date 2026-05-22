# Hifumi design system

The visible chrome of the generator app — colors, type, components, status
vocabulary — is the **Hifumi design system**. Everything below describes
what's actually wired into this codebase.

The full design canon (motif, voice rules, anti-patterns, the bundle that
seeded this) lives outside the repo as a Claude Design handoff bundle. The
intent of this file is so a contributor can find every token, every
component class, and every view that consumes them in one place.

---

## Origin

The system was applied on 2026-05-01 from a Claude Design handoff
(`hifumi-design-system` bundle: README + SKILL + `colors_and_type.css` +
17 preview cards + studio/marketing UI kits). The bundle's preview cards
went through several iteration rounds with the user — the version
implemented here reflects those final landings:

- Status indicators are **rectangular outlined boxes** in mono caps, not
  pastel-filled pills. Blinking dot for live states (`generating`,
  `running`, `starting`). **No emoji** on status tags.
- Buttons drop the legacy status emoji (`▶ ⏹ ↻ ❌ 🌀`) — labels are
  sentence-case verbs only ("Start preview", "Stop", "Retry").
- Marketing pipeline labels are **一 hi · describe → 二 fu · build →
  三 mi · run** (the three syllables of *hifumi* mapped to the user's
  mental model).

---

## Where the tokens live

```
app/assets/tailwind/application.css        ← single source of truth
   │
   ├─ @import "tailwindcss"                ← Tailwind v4 utilities
   └─ :root { --rails-500: #CC0000; ... }  ← Hifumi tokens + components
```

Both compile into `app/assets/builds/tailwind.css`. The layout pulls them
via Propshaft's `:app` glob, which also picks up the (currently empty)
manifest at `app/assets/stylesheets/application.css`.

Webfonts (IBM Plex Sans + Mono + Source Serif 4) are loaded from Google
CDN via `<link>` tags in `app/views/layouts/application.html.erb`.

---

## Token map

| Token | Value | Purpose |
|---|---|---|
| `--rails-500` | `#CC0000` | The single saturated accent. Use sparingly. |
| `--ink-800` | `#1A1714` | Primary text (warm near-black, never pure `#000`). |
| `--paper-100` | `#FAF7F2` | Primary canvas — the studio "notebook" feel. |
| `--paper-0` | `#FFFFFF` | Cards on paper. |
| `--steel-900` | `#0F1216` | Code surfaces only. |
| `--ok-line` `--info-fg` `--warn-line` `--err-fg` | desaturated greens/blues/ambers/reds | Status tags + notice stripes. |
| `--hi-font-sans` | IBM Plex Sans | UI body, headings, buttons. |
| `--hi-font-mono` | IBM Plex Mono | Labels, IDs, status pills, code, eyebrows. |
| `--hi-font-serif` | Source Serif 4 | Display moments only — marketing hero, kanji numerals. |
| `--radius-sm` (4 px) / `--radius-md` (6 px) | | Buttons / cards. Nothing larger than 10 px outside pills. |

The mono/sans/serif tri-typeface mirrors the product's mental model:
**code** (mono) — **conversation** (sans) — **announcement** (serif).

---

## Component classes

Each row links the class to the file that defines it and to the views
that consume it.

| Class | Defined in | Used in |
|---|---|---|
| `.app-nav`, `.app-nav-brand` | tailwind/application.css | layouts/application.html.erb |
| `.notice-strip` (`--ok` `--info` `--warn` `--err`) | same | layouts/application.html.erb, shared/_chat_notice, devise/shared/_error_messages |
| `.btn` (`--primary` `--accent` `--sm` `--lg`) | same | every interactive view |
| `.danger-link` | same | destructive `button_to`s — projects/index "delete", devise/registrations/edit "Disconnect GitHub" + "Cancel my account" |
| `.form-actions` | same | wraps every `f.submit` `.btn` (devise/*, projects/new, contact_messages/new, github_exports/_form) |
| `.field-input`, `.field-textarea`, `.field-label` | same | projects/new, devise/* |
| `.tag` (`--pending` `--gen` `--ok` `--err` `--running` `--starting` `--stopped` `--failed` `--new` `--generating` `--ready`) + `.tag-dot` | same | revisions/_revision, projects/index, projects/show, projects/_state_tag, previews/_* — the build-state variants (`--new` `--generating` `--ready` `--failed`) via the `project_state_tag` helper (app/helpers/projects_helper.rb) |
| `.project-card` (+ stripe + status modifier) | same | projects/index |
| `.revisions`, `.revision-row` (+ `--ok` `--gen` `--pend` `--err`) | same | revisions/_list, _revision |
| `.msg-bubble`, `.msg-role`, `.msg-pill` | same | messages/_message |
| `.composer`, `.suggestion-chip` | same | messages/_form, suggestions/_frame, projects/new |
| `.preview-pane` (+ header / body / empty / error) + `.preview-frame` | same | previews/_pane, _running, _starting, _stopped, _failed |
| `.h-display`, `.h-section`, `.lede`, `.eyebrow`, `.numeral`, `.kanji`, `.mono` | same | home/index (display + lede + kanji), layouts (nav brand kanji), home/dashboard (the one remaining `h-section` "Welcome back" + eyebrow + numeral). `.eyebrow` doubles as the page **breadcrumb** on projects/index ("projects"), projects/new + projects/show (`<nav aria-label="breadcrumb">` — parent link · current crumb), and devise/registrations/edit ("account"); a linked crumb (`.eyebrow a`) inherits the muted look, hovers accent. These pages dropped their `h1.h-section` heading in favour of the breadcrumb. `.eyebrow` also labels in-form sub-sections (devise account, projects/new). |
| `.tab-nav`, `.tab-button` (+ `.is-active`), `.tab-button__numeral`, `.tab-button__label` | same | projects/show (via projects/_tab_nav: 一 build · 二 preview · 三 export), projects/new (inline, single 一 step), devise/registrations/edit (account page: inline 一 profile · 二 integrations · 三 danger zone, default profile, no URL state — same client-side `display`-toggle convention as Studio, driven by the shared `tabs` Stimulus controller; the OpenRouter rotate-key form lives in the Integrations tab and still posts to the Devise registration `update` endpoint) |
| `.pipeline`, `.pipeline-step` | same | home/index (一 / 二 / 三 stages) |
| `.dash-stats` (+ `--total`), `.dash-stat` (+ `__num` `__label`), `.dash-actions`, `.dash-cta`, `.dash-link` | same | home/dashboard |
| `.page-head` (+ `--spread`) | same | the fixed-height breadcrumb/eyebrow bar — home/dashboard, projects/index + new + show, devise/registrations/edit |

---

## Button color semantics

**Every button is either black or red — there is no in-between** (no
outlined, ghost, or tinted buttons). The `.btn` color modifier is **not**
chosen per view — it follows one predicate. Pick by *what the action does*,
not by which screen it sits on:

| Modifier | Means | Representative buttons |
|---|---|---|
| `--accent` (red) | **Create / begin / start** a new thing or operation | "Sign up", "Start building", "Start preview", "+ New project" |
| `--primary` (black) | Everything else that is a button — routine submits *and* secondary actions | "Log in", "Update account", "Update key", "Connect GitHub", "Change my password", "Send" (composer + contact), "Export to GitHub", "Retry", "Accept", "Stop", "Push latest changes", "Create a new repository", "Decline" |

`--accent` maps to `--rails-500`, "the single saturated accent — use
sparingly" (see Token map). The create/begin/start bucket *is* that sparing
use: it should appear at most once per surface, on the one button that
starts something new. Everything else that is a button is `--primary`
(black), never `--accent`.

### Destructive actions are red links, not buttons

Delete / remove / disconnect actions (project-card "delete", "Cancel my
account", "Disconnect GitHub") are **not buttons**. They render as a text
link in the brand accent red via `.danger-link` (resets `button_to` chrome;
`color: var(--accent)`, underline on hover) — the *same* red as the red
buttons, deliberately **not** a separate brick/error red. Rationale: a
destructive action should never carry the visual weight of a filled button;
the red text is the warning, the link affordance keeps it low-commitment.

### One button in the nav

The top nav contains **exactly one** `.btn`: the signed-out "Sign up"
(`btn btn--accent btn--sm`), the single conversion CTA. Every other nav item
— "Log in", "Projects", "Account", "Sign out", the GitHub icon — is a
navigation link in the `.app-nav-link` family, never a `.btn`. Signed-in,
the nav has **zero** `.btn`s. "Log in" is a link, not a button, even though
it pairs visually with the "Sign up" button.

### Choosing the button helper

Pick the Rails helper by *what kind of interaction it is* — then style it
with `.btn` (or, for navigation, the link family):

- **Form submit** (inside `form_for` / `form_with`) → `f.submit` + `.btn`,
  wrapped in `.form-actions` — *unless* the form lives in a self-laying-out
  component that already owns submit placement (see exceptions).
- **State-changing action outside a form** (POST / PATCH / DELETE) →
  `button_to`; **destructive** (delete / remove / disconnect) → `.danger-link`
  (red text link), everything else → `.btn`.
- **Navigation (GET)** → `link_to`; a primary navigational CTA may carry
  `.btn` (e.g. "+ New project"), otherwise the navigation-link family
  (`.app-nav-link`, `.dash-cta`, `.dash-link`, `↗`-suffixed anchors,
  `devise/shared/_links`).
- **Client-side-only control** (Stimulus, no server round-trip) → raw
  `<button type="button">` + its own component class, **never** `.btn`
  (`.suggestion-card`, `.tab-button`, `.composer-dock__jump`,
  `.notice-strip__close`) — *unless* it sits in an action group beside a
  server-submitting `.btn` and must read as its visual pair (see exceptions).

Every interactive element is one of the four above. The narrow, deliberate
exceptions — each kept consistent in code so canon doesn't lag:

- **Self-laying-out form components own their submit.** The composer
  ("Send", `messages/_form`) and the cookie bar ("Accept",
  `shared/_cookie_consent`) are horizontal flex docks; their `f.submit` is a
  `.btn` but *not* wrapped in `.form-actions` (a block `margin-top` wrapper
  would break the inline layout). `.form-actions` is only for stacked
  column forms.
- **Paired client-side controls use `.btn` for visual parity.** The cookie
  bar "Decline" and the cookies-required "Show cookie banner" are
  Stimulus-only (no server round-trip) yet carry `.btn` so they read as the
  matched pair of the adjacent server-submitting button. Standalone JS
  controls still use their own component class.
- **"Sign out" is a `button_to` styled as a nav link.** Logout must be a
  POST/DELETE, but it lives in the nav, so it uses `.app-nav-link`, not
  `.btn` (see *One button in the nav*).

---

## Status vocabulary

The status verbs in the codebase map to two display patterns:

| Verb | Where | Stripe color | Tag color | Live? |
|---|---|---|---|---|
| `pending` | revision | `--ink-200` | `--fg-faint` | – |
| `generating` | revision | `--info-fg` | `--info-fg` | dot blinks |
| `completed` | revision | `--ok-line` | `--ok-line` | – |
| `failed` | revision, preview | `--accent` | `--accent` | – |
| `stopped` | preview | `--ink-300` | `--fg-muted` | – |
| `starting` | preview | `--info-fg` | `--info-fg` | dot blinks |
| `running` | preview | `--ok-line` | `--ok-line` | dot blinks |
| `failed` | preview, project card (build-failed) | `--accent` | `--accent` | – |
| `new` | project card | `--ink-300` | `--fg-muted` | – |
| `generating` | project card (build state — CSS class `--generating`, distinct from the revision `--gen`) | `--info-fg` | `--info-fg` | dot blinks |
| `ready` | project card | `--ok-line` | `--ok-line` | – |

The four build-state verbs (`new` / `generating` / `failed` / `ready`) also
appear as `.dash-stat__label` text on the dashboard build-state breakdown.

Verbs are always **lowercase in source**, **uppercase via CSS
`text-transform`** in the rendered tag — never title-cased in copy.

---

## Voice and copy

- Sentence case in every UI string. ✅ "New project" — ❌ "New Project".
- Lowercase domain in body copy: `hifumi.dev`.
- Engineer-to-engineer. No "AI-powered", "magical", "10×", "supercharge".
- Em-dashes are encouraged. Numbered specifics over vague claims
  ("10–30 s typical (longer on first build)" beats "fast").
- Code-y nouns stay in backticks: `bin/dev`, `Roast`, `OpenRouter`,
  `Solid Queue`.
- Status verbs lowercase: pending, generating, completed, failed,
  starting, running, stopped.
- Decorative kanji **一 二 三** in Source Serif 4 at display sizes for
  landing / empty states / pipeline diagrams / top-nav brand.
  Decorative only — never load-bearing as the only label.

---

## Anti-patterns (don't ship)

- **Gradients.** Anywhere. Solid fills only.
- **Glassmorphism / backdrop-blur / frosted panels.**
- **Big drop shadows.** Reach for a 1-px hairline border first.
- **"Rounded corners + colored left-border accent" cards.** Banned.
- **Bouncy / springy easing.** Standard ease is
  `cubic-bezier(0.2, 0, 0, 1)`, durations 120 / 180 / 320 ms.
- **Stock photography, 3D renders, AI-generated illustrations,
  robot mascots, magic-wand sparkles, lightning bolts.**
- **Title case in UI strings.** Sentence case everywhere.
- **New emoji.** The only allowed emoji are the canonical six (`⏸ ⏳ ✅
  ❌ ▶ ⏹ ↻ ↗`) and they exist for backwards-compatibility — the
  current chrome doesn't use them anymore.

---

## How to add a new component

1. Define the class in `app/assets/tailwind/application.css`. Use the
   existing tokens (`--accent`, `--paper-0`, `--ink-800`, `--hi-font-mono`,
   etc.) — never hardcode hex values.
2. Pick the smallest radius that works (`--radius-sm` 4 px for inputs,
   `--radius-md` 6 px for cards, no radius for tags).
3. Run `bin/rails tailwindcss:build` to recompile (the `bin/dev`
   Procfile keeps a watcher running).
4. If the component represents a status, follow the **stripe + outlined
   tag** pattern from `.project-card` / `.revision-row` — don't invent a
   new pastel-filled style.

---

## Adding a new status verb

1. Pick the stripe color and tag color from the token map (status hues
   only — no new saturated colors).
2. Add the modifier classes: `.tag--<verb>`, `.<container>--<verb>` for
   stripe.
3. If the state is *live* (something is happening), include the
   `<span class="tag-dot"></span>` glyph inside the tag — it inherits
   `currentColor` and blinks at 1.1 s.
4. Use the verb verbatim — lowercase — as the tag text. The CSS handles
   uppercase rendering.
