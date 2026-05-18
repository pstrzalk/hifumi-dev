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
| `.btn` (`--primary` `--accent` `--outline` `--danger` `--sm` `--lg`) | same | every interactive view |
| `.form-actions` | same | wraps every `f.submit` `.btn` (devise/*, projects/new, contact_messages/new, github_exports/_form) |
| `.field-input`, `.field-textarea`, `.field-label` | same | projects/new, devise/* |
| `.tag` (`--pending` `--gen` `--ok` `--err` `--running` `--starting` `--stopped` `--failed`) + `.tag-dot` | same | revisions/_revision, projects/index, previews/_* |
| `.project-card` (+ stripe + status modifier) | same | projects/index |
| `.revisions`, `.revision-row` (+ `--ok` `--gen` `--pend` `--err`) | same | revisions/_list, _revision |
| `.msg-bubble`, `.msg-role`, `.msg-pill` | same | messages/_message |
| `.composer`, `.suggestion-chip` | same | messages/_form, suggestions/_frame, projects/new |
| `.preview-pane` (+ header / body / empty / error) + `.preview-frame` | same | previews/_pane, _running, _starting, _stopped, _failed |
| `.h-display`, `.h-section`, `.lede`, `.eyebrow`, `.numeral`, `.kanji`, `.mono` | same | home/index (display + lede + kanji), projects/* (eyebrow + section), studio, layouts (nav brand kanji), home/dashboard (eyebrow + section + numeral), devise/registrations/edit (account page: page-level `eyebrow` + `h1.h-section "Account"`) |
| `.tab-nav`, `.tab-button` (+ `.is-active`), `.tab-button__numeral`, `.tab-button__label` | same | projects/show (via projects/_tab_nav: 一 build · 二 preview · 三 export), projects/new (inline, single 一 step), devise/registrations/edit (account page: inline 一 profile · 二 integrations · 三 danger zone, default profile, no URL state — same client-side `display`-toggle convention as Studio, driven by the shared `tabs` Stimulus controller; the OpenRouter rotate-key form lives in the Integrations tab and still posts to the Devise registration `update` endpoint) |
| `.pipeline`, `.pipeline-step` | same | home/index (一 / 二 / 三 stages) |
| `.dash-stats`, `.dash-stat` (+ `__num` `__label`), `.dash-actions`, `.dash-cta`, `.dash-link` | same | home/dashboard |

---

## Status vocabulary

The eight status verbs in the codebase map to two display patterns:

| Verb | Where | Stripe color | Tag color | Live? |
|---|---|---|---|---|
| `pending` | revision | `--ink-200` | `--fg-faint` | – |
| `generating` | revision | `--info-fg` | `--info-fg` | dot blinks |
| `completed` | revision | `--ok-line` | `--ok-line` | – |
| `failed` | revision, preview | `--accent` | `--accent` | – |
| `stopped` | preview, project card | `--ink-300` | `--fg-muted` | – |
| `starting` | preview, project card | `--info-fg` | `--info-fg` | dot blinks |
| `running` | preview, project card | `--ok-line` | `--ok-line` | dot blinks |
| `failed` | preview, project card | `--accent` | `--accent` | – |

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
