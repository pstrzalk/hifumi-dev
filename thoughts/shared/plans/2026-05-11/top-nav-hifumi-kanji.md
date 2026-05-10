---
date: 2026-05-11
planner: Paweł Strzałkowski
git_commit: 0c724e40a8ac218bd18e93ae6bf2630c40084418
branch: main
repository: rails-app-generator
topic: "Top-nav brand — prepend 一二三 kanji to hifumi.dev wordmark"
tags: [plan, design, hifumi, top-nav, kanji, branding]
status: ready
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Top-nav `一二三 hifumi.dev` wordmark — Implementation Plan

## Overview

Prepend the decorative kanji `一二三` to the top-nav brand wordmark so the
mark reads **`一二三 hifumi.dev`** — kanji in accent-tinted Source Serif 4,
wordmark in IBM Plex Sans, `.dev` in IBM Plex Mono as today. One commit,
three files: layout markup, Tailwind CSS, and a design-system canon
update.

## Current State Analysis

The wordmark today is `hifumi<span class="tld">.dev</span>` rendered
twice in `app/views/layouts/application.html.erb` — once in the
`user_signed_in?` branch (line 31, links to `projects_path`), once in
the anonymous branch (line 39, links to `root_path`). The CSS for it
lives in `app/assets/tailwind/application.css:220-234`:

- `.app-nav-brand` — IBM Plex Sans, weight 600, 24 px, color `--fg`,
  `margin-right: auto` (right-aligns every sibling in the nav).
- `.app-nav-brand .tld` — IBM Plex Mono, weight 500, color `--fg-muted`,
  `margin-left: 1px`.

The `.kanji` utility class is defined at
`app/assets/tailwind/application.css:176-180` — Source Serif 4, weight
400, letter-spacing 0.06em. No size set; inherits from the parent.
Source Serif 4 is already loaded by the layout's Google Fonts `<link>`
(line 21), so no font work is needed.

Kanji `一二三` already render in three other surfaces (marketing
eyebrow, marketing pipeline, studio tabs) — all through `.kanji`. None
of the test suite asserts nav-brand HTML
(`grep -rn "app-nav\|hifumi<" test/` → empty), so the change is purely
visual with no automated-test impact.

## Desired End State

The top nav, on every authenticated and anonymous route, renders:

```
[ 一二三 hifumi.dev ]   …links…
  ↑ Source Serif 4, weight 400, --accent, 24 px, 0.06em tracking
       ↑ 0.4em gap (margin-right on the kanji span)
              ↑ Plex Sans 600, --fg
                     ↑ Plex Mono 500, --fg-muted
```

On hover of the brand link, the wordmark transitions from `--fg` to
`--accent` (existing behaviour), unifying the colour of kanji +
wordmark. The kanji is `aria-hidden="true"`; the accessible link label
remains `"hifumi.dev"`.

### Key Discoveries:
- Mixed-typeface wordmark is already the codebase's pattern — `.tld`
  inside `.app-nav-brand` is the precedent for layering a second
  typographic register inside the brand mark
  (`app/assets/tailwind/application.css:229-234`).
- `.kanji` utility class already supplies serif + weight 400 +
  letter-spacing — so the new `.app-nav-brand .kanji` rule only needs
  to add **colour** and **margin-right** on top.
- `margin-right: auto` on `.app-nav-brand` is what right-aligns every
  sibling. Keeping the kanji **inside** `.app-nav-brand` (not as a
  sibling) means we don't touch that flex plumbing.
- The kanji is `aria-hidden="true"` to match the studio-tab precedent
  (`app/views/projects/_tab_nav.html.erb:29`); screen readers continue
  to say "hifumi.dev".
- `<title>` (line 4) and `<meta name="application-name">` (line 7)
  stay `hifumi.dev` — design-system voice rule keeps the lowercase
  domain as the canonical brand string in copy; kanji is decoration.

## What We're NOT Doing

- **No new tests.** Pure visual layout change with no logical branches;
  the existing suite covers regression (any layout-render breakage
  fails every controller test).
- **No font work.** Source Serif 4 is already loaded by the layout.
- **No change to `<title>` or `application-name` meta.** Kanji is
  decorative; the canonical brand string in copy stays `hifumi.dev`.
- **No new helper / partial.** Wordmark is two ERB lines duplicated
  across auth branches; that's already how the codebase ships it, and
  extracting a partial for a two-line literal is over-abstraction. Both
  branches get edited verbatim.
- **No accent-aware hover swap or kanji-shift on hover.** Kanji sits at
  `--accent` always; on hover the wordmark catches up to it. Simpler
  CSS, one less rule to maintain.
- **No `.app-nav-brand` selector rename / no new modifier class.**
  Existing class names stay.

## Implementation Approach

Add a leading `<span class="kanji" aria-hidden="true">一二三</span>`
inside `.app-nav-brand` (both auth branches), add a four-property
selector to `application.css` scoped to `.app-nav-brand .kanji`, and
extend the design-system doc's kanji-surface inventory to include the
nav.

## Phase 1: Prepend 一二三 kanji to top-nav brand

### Commit
`design: top nav — prepend 一二三 to hifumi.dev wordmark`

### Overview
Single atomic change touching three files: layout ERB (markup), Tailwind
CSS (colour + spacing), design-system doc (canon update).

### Changes Required:

#### 1. Layout — add kanji span to both wordmark renders
**File**: `app/views/layouts/application.html.erb`

**Line 31** (signed-in branch) — replace:
```erb
<%= link_to projects_path, class: "app-nav-brand" do %>hifumi<span class="tld">.dev</span><% end %>
```
with:
```erb
<%= link_to projects_path, class: "app-nav-brand" do %><span class="kanji" aria-hidden="true">一二三</span>hifumi<span class="tld">.dev</span><% end %>
```

**Line 39** (anonymous branch) — replace:
```erb
<%= link_to root_path, class: "app-nav-brand" do %>hifumi<span class="tld">.dev</span><% end %>
```
with:
```erb
<%= link_to root_path, class: "app-nav-brand" do %><span class="kanji" aria-hidden="true">一二三</span>hifumi<span class="tld">.dev</span><% end %>
```

The kanji span is the **first child** of `.app-nav-brand`, before the
literal `hifumi` text node. No literal whitespace between the kanji
span and `hifumi` — the gap is delivered by CSS.

#### 2. Tailwind CSS — scoped rule for nav kanji
**File**: `app/assets/tailwind/application.css`

Insert a new rule **after line 234** (the `.app-nav-brand .tld` block,
keeping the nav-brand selectors grouped together, and before
`.app-nav-sep` on line 235):

```css
.app-nav-brand .kanji {
  color: var(--accent);
  margin-right: 0.4em;
}
```

Why only two properties: the `.kanji` utility class at
`application.css:176-180` already supplies `font-family:
var(--hi-font-serif)`, `font-weight: 400`, and `letter-spacing:
0.06em`. Font-size and line-height are inherited from `.app-nav-brand`
(24 px), which is the design choice. The new rule only needs to
**override** the colour (parent says `--fg`; we want `--accent`) and
**add** the gap before `hifumi`.

#### 3. Design-system doc — add nav as a kanji surface
**File**: `docs/02-architecture/04-design-system.md`

**Line 88** — extend the "Used in" column for the `.kanji` row.
Replace:
```
| `.h-display`, `.h-section`, `.lede`, `.eyebrow`, `.numeral`, `.kanji`, `.mono` | same | home/index (display + lede + kanji), projects/* (eyebrow + section), studio |
```
with:
```
| `.h-display`, `.h-section`, `.lede`, `.eyebrow`, `.numeral`, `.kanji`, `.mono` | same | home/index (display + lede + kanji), projects/* (eyebrow + section), studio, layouts (nav brand kanji) |
```

**Lines 124-126** — add nav to the kanji-surface list. Replace:
```
- Decorative kanji **一 二 三** in Source Serif 4 at display sizes for
  landing / empty states / pipeline diagrams. Decorative only — never
  load-bearing as the only label.
```
with:
```
- Decorative kanji **一 二 三** in Source Serif 4 at display sizes for
  landing / empty states / pipeline diagrams / top-nav brand.
  Decorative only — never load-bearing as the only label.
```

### Success Criteria:

#### Automated Verification:
- [x] Full test suite passes: `bin/rails test` — 354 runs, 1264 assertions, 1 failure (unrelated: pre-existing WIP on `_tab_nav.html.erb` simplified labels, breaking `ProjectsControllerShowTest#test_renders_three_tab_buttons_…`). No test asserts nav-brand HTML (`grep -rn "app-nav\|hifumi<\|app-nav-brand" test/` → empty).
- [ ] Tailwind build emits the new selector without error: visit any
      page in dev (`bin/dev`) and confirm no compilation error in the
      Tailwind log.

#### Manual Verification:
- [ ] **Logged-out** — visit `/`: nav reads `一二三 hifumi.dev` followed
      by `Log in · Sign up`. Kanji is red (`--accent`), wordmark is
      ink-dark, `.dev` is muted-mono.
- [ ] **Logged-in** — visit `/projects`: nav reads `一二三 hifumi.dev`
      followed by `Projects · Account · [Sign out]`. Active state on
      `Projects` (accent underline) still renders correctly.
- [ ] **Hover the brand** — wordmark `hifumi.dev` transitions to
      `--accent`, kanji stays at `--accent`; the whole mark unifies on
      a red beat. (The `.tld` stays muted because it has its own
      explicit colour — same as today's behaviour.)
- [ ] **Click the brand** — logged-in routes to `/projects`,
      logged-out routes to `/` (no link-target regression).
- [ ] **Kanji spacing** — visually inspect the gap; 0.4 em at 24 px
      ≈ 9.6 px; should read as one tight unit, not two beats.
      Adjust to 0.5 em if it reads too cramped, 0.3 em if too loose.
- [ ] **Narrow viewport** — at the design system's smallest target,
      brand + nav links still fit on one line without wrapping. (The
      brand is now ~6 glyphs wider; eyeball at 1024 px and 768 px.)
- [ ] **Screen-reader sanity** — VoiceOver / TalkBack reads the brand
      link as "hifumi.dev", not "one two three hifumi.dev". (Confirm
      `aria-hidden="true"` is working.)
- [ ] **No regression on other kanji surfaces** — marketing eyebrow,
      marketing pipeline, studio tabs render unchanged (the scoped
      `.app-nav-brand .kanji` rule must not bleed into them).

**Implementation Note**: After completing this phase and `bin/rails
test` passes, pause for the manual visual sweep above before committing.

---

## Testing Strategy

### Unit / Integration Tests:
None added. This is a pure visual layout change with no logical
branches. The existing test suite (every controller test renders the
layout) catches any markup-level regression — if the ERB breaks,
hundreds of tests fail in chorus.

### Manual Testing Steps:
1. Run `bin/dev` and open `/` while logged out — confirm wordmark renders.
2. Sign in (or use a seeded account), navigate to `/projects` — confirm
   wordmark renders identically and the `.active` underline on
   `Projects` still works.
3. Hover the brand link — wordmark catches up to accent red; kanji stays accent.
4. Right-click the brand → "Inspect element" — confirm kanji span has
   `class="kanji"`, `aria-hidden="true"`, and computed style shows
   Source Serif 4 + colour `--accent`.
5. Toggle dev tools' "Rendering → Emulate vision deficiencies" → "no
   sight" (or VoiceOver) — confirm the brand link is announced as
   `"hifumi.dev"` only.
6. Resize browser to ≤ 768 px wide — nav still fits one line.

## Performance Considerations

None. Three CSS properties and 30 bytes of HTML per render. Source
Serif 4 already on the critical path.

## Migration Notes

None. No data, no backwards compatibility, no feature flag — pure
visual change shipped in one deploy.

## References

- Research: `thoughts/shared/research/2026-05-11/top-nav-hifumi-brand.md`
- Current wordmark: `app/views/layouts/application.html.erb:31,39`
- Current CSS: `app/assets/tailwind/application.css:220-234`
- `.kanji` utility: `app/assets/tailwind/application.css:176-180`
- Studio-tab kanji precedent: `app/views/projects/_tab_nav.html.erb:29`
- Marketing pipeline kanji precedent: `app/views/home/index.html.erb:20,30,40`
- Design canon: `docs/02-architecture/04-design-system.md:88,124-126`
