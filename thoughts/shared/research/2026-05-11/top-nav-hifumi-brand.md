---
date: 2026-05-11
researcher: Paweł Strzałkowski
git_commit: 0c724e40a8ac218bd18e93ae6bf2630c40084418
branch: main
repository: rails-app-generator
topic: "Top-nav `hifumi.dev` brand wordmark — where it's rendered and how it's styled"
tags: [research, codebase, layout, design-system, hifumi, top-nav, branding]
status: complete
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Research: Top-nav `hifumi.dev` brand wordmark

**Date**: 2026-05-11
**Researcher**: Paweł Strzałkowski
**Git Commit**: 0c724e40a8ac218bd18e93ae6bf2630c40084418
**Branch**: main
**Repository**: rails-app-generator

## Research Question
The top nav contains the text `hifumi.dev`. Where is it rendered, how is it styled, and what does the surrounding markup look like? (Context for a forthcoming change: prepending the kanji `一二三` so the brand reads `一二三 hifumi.dev`.)

## Summary

The top-nav brand wordmark is rendered in exactly **one file** — `app/views/layouts/application.html.erb` — but appears **twice** inside that file as two near-identical branches of an `if user_signed_in?` conditional. Both branches render the same markup:

```erb
hifumi<span class="tld">.dev</span>
```

inside an `<%= link_to … class: "app-nav-brand" do %>` block. Only the link target differs (`projects_path` when signed in, `root_path` otherwise).

The wordmark is split into two typographic registers via the `<span class="tld">` element: `hifumi` renders in IBM Plex Sans (the brand mark) and `.dev` renders in IBM Plex Mono (the TLD, treated as code-y / subordinate). All styling lives in `app/assets/tailwind/application.css` under `.app-nav-brand` and `.app-nav-brand .tld`.

The kanji `一二三` glyphs already appear elsewhere in the app (marketing eyebrow, marketing pipeline, studio tab-nav), all rendered through a shared `.kanji` utility class (`Source Serif 4`, weight 400, letter-spacing 0.06em). The Source Serif 4 webfont is already loaded by the layout, so the `.kanji` typography is available inside the top nav without additional setup. Design-system canon (`docs/02-architecture/04-design-system.md`) flags 一 二 三 as "decorative kanji … at display sizes for landing / empty states / pipeline diagrams" and currently does **not** list the top nav as a kanji surface.

## Detailed Findings

### Brand rendered in the layout

[`app/views/layouts/application.html.erb`](app/views/layouts/application.html.erb) holds the entire nav.

- Line 4: `<title><%= content_for(:title) || "hifumi.dev" %></title>` — browser tab title.
- Line 7: `<meta name="application-name" content="hifumi.dev">` — application name meta.
- Line 21: Google Fonts `<link>` loads **IBM Plex Sans + IBM Plex Mono + Source Serif 4**, so all three Hifumi typefaces are available in the nav.
- Lines 28-45: the `<nav class="app-nav"> <div class="app-nav-inner"> … </div> </nav>` block.

Inside `.app-nav-inner` there are two render branches:

```erb
<% if user_signed_in? %>
  <%= link_to projects_path, class: "app-nav-brand" do %>hifumi<span class="tld">.dev</span><% end %>
  <%= link_to "Projects", projects_path, class: "app-nav-link#{' active' if controller_name == 'projects'}" %>
  <span class="app-nav-sep">·</span>
  <%= link_to "Account", edit_user_registration_path %>
  <span class="app-nav-sep">·</span>
  <%= button_to "Sign out", destroy_user_session_path, method: :delete,
      form: { class: "inline" }, class: "btn btn--ghost btn--sm" %>
<% else %>
  <%= link_to root_path, class: "app-nav-brand" do %>hifumi<span class="tld">.dev</span><% end %>
  <%= link_to "Log in", new_user_session_path %>
  <span class="app-nav-sep">·</span>
  <%= link_to "Sign up", new_user_registration_path, class: "btn btn--accent btn--sm" %>
<% end %>
```

The brand link is the **first child** of `.app-nav-inner` in both branches. Differences between branches:

| | Signed in (line 31) | Anonymous (line 39) |
|---|---|---|
| Brand target | `projects_path` | `root_path` |
| Adjacent links | Projects, Account, Sign out | Log in, Sign up |

The wordmark markup itself (`hifumi<span class="tld">.dev</span>`) is identical across both branches.

### Brand CSS

[`app/assets/tailwind/application.css`](app/assets/tailwind/application.css) — all selectors below live in the single Tailwind layer file documented in CLAUDE.md.

```css
/* lines 198-205 — the nav strip itself */
.app-nav {
  position: sticky;
  top: 0;
  z-index: 30;
  background: var(--bg);
  border-bottom: 1px solid var(--rule);
  height: 60px;
}

/* lines 206-217 — flex row holding the brand + links */
.app-nav-inner {
  max-width: 1600px;
  margin: 0 auto;
  height: 100%;
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0 24px;
  font-family: var(--hi-font-sans);
  font-size: 22px;
  color: var(--fg);
}

/* lines 218-219 — link reset for anything inside the inner row */
.app-nav-inner a:not(.btn) { color: var(--fg); text-decoration: none; }
.app-nav-inner a:not(.btn):hover { color: var(--accent); }

/* lines 220-228 — "hifumi" mark */
.app-nav-brand {
  font-family: var(--hi-font-sans);
  font-weight: 600;
  font-size: 24px;
  letter-spacing: -0.01em;
  color: var(--fg);
  text-decoration: none;
  margin-right: auto;            /* pushes every sibling to the right */
}

/* lines 229-234 — the ".dev" TLD */
.app-nav-brand .tld {
  font-family: var(--hi-font-mono);
  font-weight: 500;
  color: var(--fg-muted);
  margin-left: 1px;
}

/* lines 235-236 — neighbouring nav decoration */
.app-nav-sep { color: var(--fg-faint); }
.app-nav-link.active { color: var(--accent); border-bottom: 2px solid var(--accent); padding-bottom: 4px; }
```

Key facts:

- The nav is **60 px tall, sticky to the top**, with a `--rule` hairline bottom border.
- The brand link uses `margin-right: auto`, which is what right-aligns the rest of the nav. Anything inserted **before** the wordmark would sit between the left edge and the wordmark; anything inserted **inside** `.app-nav-brand` would inherit its `font-family: sans-serif` and `font-weight: 600` unless re-typed.
- The `.tld` span is the codebase's existing precedent for *mixing typefaces inside the wordmark* — sans for the brand, mono for the TLD, with one CSS rule per segment.

### Kanji glyphs already present in the codebase

The string `一二三` (and its decomposed forms 一 / 二 / 三) appear in three view surfaces:

1. **Marketing eyebrow** — [`app/views/home/index.html.erb:3`](app/views/home/index.html.erb)
   ```erb
   <span class="eyebrow">hifumi · 一二三 · hi-fu-mi</span>
   ```
   Renders as a small mono uppercase strip above the hero (no explicit `.kanji` class; the eyebrow's font carries the glyphs through font fallback).

2. **Marketing pipeline (three steps)** — [`app/views/home/index.html.erb:20,30,40`](app/views/home/index.html.erb)
   ```erb
   <div class="pipeline-step__numeral kanji">一</div>
   <div class="pipeline-step__numeral kanji">二</div>
   <div class="pipeline-step__numeral kanji">三</div>
   ```
   These are large display numerals, one per stage.

3. **Studio tab-nav** — [`app/views/projects/_tab_nav.html.erb:29`](app/views/projects/_tab_nav.html.erb)
   ```erb
   <span class="tab-button__numeral kanji" aria-hidden="true"><%= glyph %></span>
   ```
   Per-tab kanji glyph (`work` / `talk` / `live` use 一 / 二 / 三 respectively in the partial's data).

### The `.kanji` utility class

[`app/assets/tailwind/application.css:176-180`](app/assets/tailwind/application.css):

```css
.kanji {
  font-family: var(--hi-font-serif);  /* Source Serif 4 */
  font-weight: 400;
  letter-spacing: 0.06em;
}
```

There's also a sibling `.numeral` class (lines 170-174) for tabular-figure Latin numerals in Source Serif. Both are documented in the design system as part of the typography ramp.

### Design-system canon on the wordmark and kanji

[`docs/02-architecture/04-design-system.md`](docs/02-architecture/04-design-system.md):

- **Line 63**: Source Serif 4 is reserved for "Display moments only — marketing hero, kanji numerals."
- **Lines 27-29**: The marketing pipeline is canonically labeled **一 hi · describe → 二 fu · build → 三 mi · run** — the three syllables of *hifumi* mapped to the user journey.
- **Line 78**: The component inventory table lists `.app-nav, .app-nav-brand` as defined in `tailwind/application.css` and consumed in `layouts/application.html.erb` only.
- **Line 88**: Kanji utility is documented as `.kanji` used in "home/index (display + lede + kanji)" and "projects/* (eyebrow + section), studio".
- **Line 116**: Voice rule — "Lowercase domain in body copy: `hifumi.dev`."
- **Lines 124-126**: "Decorative kanji **一 二 三** in Source Serif 4 at display sizes for landing / empty states / pipeline diagrams. Decorative only — never load-bearing as the only label."

The design-system doc currently lists kanji surfaces as **landing / empty states / pipeline diagrams / studio tabs** — the top nav is not enumerated as a kanji surface.

### Other places `hifumi.dev` appears (non-nav)

For completeness, the string `hifumi.dev` is used as configuration / canonical brand outside the nav:

- `app/models/project.rb:14-15` — git commit author identity (`hifumi.dev` / `code@hifumi.dev`).
- `app/views/home/index.html.erb:45` — body-copy reference to `<id>.preview.hifumi.dev`.
- `config/environments/production.rb:69` — Action Mailer host.
- `config/initializers/devise.rb:27` — Devise `mailer_sender`.
- `config/initializers/preview_config.rb:2` — `PREVIEW_DOMAIN` env var doc comment.
- `config/initializers/content_security_policy.rb:11` — CSP iframe origin comment.
- Multiple tests under `test/` reference the literal as expected output.

None of these are the top-nav surface; they're listed only to clarify the scope of "the wordmark".

## Code References

- `app/views/layouts/application.html.erb:31` — brand link, signed-in branch.
- `app/views/layouts/application.html.erb:39` — brand link, anonymous branch.
- `app/views/layouts/application.html.erb:21` — Google Fonts `<link>` (Source Serif 4 loaded).
- `app/views/layouts/application.html.erb:28-45` — full nav block.
- `app/assets/tailwind/application.css:198-205` — `.app-nav` strip.
- `app/assets/tailwind/application.css:206-217` — `.app-nav-inner` flex container.
- `app/assets/tailwind/application.css:220-228` — `.app-nav-brand` mark.
- `app/assets/tailwind/application.css:229-234` — `.app-nav-brand .tld` mono segment.
- `app/assets/tailwind/application.css:170-180` — `.numeral` and `.kanji` utilities.
- `app/views/home/index.html.erb:3` — existing `一二三` glyph string in marketing eyebrow.
- `app/views/home/index.html.erb:20,30,40` — pipeline kanji per stage.
- `app/views/projects/_tab_nav.html.erb:29` — studio tab kanji glyph.
- `docs/02-architecture/04-design-system.md:63,88,124-126` — design canon on kanji.

## Architecture Documentation

- **Single layout, single CSS file.** The Hifumi stack uses one ERB layout (`application.html.erb`) and one CSS source (`app/assets/tailwind/application.css`) for all chrome. Any change to the nav touches exactly those two files.
- **Mixed-typeface wordmark pattern.** The current wordmark already mixes Plex Sans (`hifumi`) with Plex Mono (`.tld`) inside a single `<a class="app-nav-brand">`. The pattern is: outer element sets the default register, inner `<span>` overrides `font-family` + `font-weight` + `color` for the secondary register.
- **Duplicate auth branches.** The signed-in and anonymous brand links are duplicated verbatim except for the link target. Any wordmark markup change has to be applied to both lines.
- **Layout already loads the kanji font.** Source Serif 4 is in the Google Fonts `<link>` regardless of route, so `.kanji` glyphs render correctly in any view that uses the layout — no additional preconnect / font-import work is needed to introduce kanji into the nav.
- **`margin-right: auto` is what right-aligns the rest of the nav.** It lives on `.app-nav-brand`. Anything visually grouped *with* the wordmark (e.g. a kanji glyph to the left of it) would either need to live inside `.app-nav-brand` (and inherit the `auto` push), or live in a wrapper that itself carries `margin-right: auto` while the original brand loses it.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-04-28/phase-4b-preview-refactors.md` and `thoughts/shared/plans/2026-04-28/phase-4d-deploy-and-wrapup.md` — establish `hifumi.dev` as the production host and `<id>.preview.hifumi.dev` as the per-preview subdomain. Anchors the brand string as a real DNS name, not only a wordmark.
- No prior research document covers the top-nav brand specifically. The nearest neighbour is `thoughts/shared/research/2026-05-11/projects-list-row-height-and-info.md` (same day, separate concern).

## Related Research

- `thoughts/shared/research/2026-05-11/projects-list-row-height-and-info.md` — adjacent Hifumi UI surface.
- Several earlier `thoughts/shared/research/2026-05-*/` files cover Hifumi typography ramp and studio chrome (per memory: typography ramp + studio-tabs/chat-bubble research has been planned/implemented in recent commits).

## Open Questions

None for documentation purposes — the current state of the wordmark is fully described above. (Any decisions about where exactly `一二三` should sit relative to the wordmark, what class it should carry, and whether to update the design-system doc to add the nav as a kanji surface, are change-time decisions outside the scope of this research.)
