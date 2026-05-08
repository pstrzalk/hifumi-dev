---
date: 2026-05-08
researcher: Paweł Strzałkowski
git_commit: e74581e11ccc5cbbe7425b5018c25e46dbdb42ee
branch: main
repository: rails-app-generator
topic: "Authenticated-screen layout widths and project-show section structure (precursor to tabbing Hi/Build · Fu/Preview · Mi/Export)"
tags: [research, codebase, layout, hifumi, project-show, devise, width, tabs]
status: complete
last_updated: 2026-05-08
last_updated_by: Paweł Strzałkowski
---

# Research: Authenticated-screen layout widths and project-show section structure

**Date**: 2026-05-08
**Researcher**: Paweł Strzałkowski
**Git Commit**: e74581e11ccc5cbbe7425b5018c25e46dbdb42ee
**Branch**: main
**Repository**: rails-app-generator

## Research Question

When the user is logged in, almost every screen uses a different body width — the project show page uses `max-width: 1120px` while account/list screens use much narrower wrappers, and the marketing shell uses 1280px. Document:

1. Where every authenticated screen sets its width and which value it uses.
2. Where the `1120px` figure specifically lives and what other elements depend on it (top nav, flash strips).
3. The current section topology of the project show page (`/projects/:id`) — chat/build, preview, GitHub export — including the partials, turbo frames, broadcast targets, and controller wiring that make each section work, as a baseline for evaluating a future tab grouping (Hi · Build / Fu · Preview / Mi · Export).
4. Any historical decisions in `thoughts/` and `docs/` about page width consistency, tab navigation, or section grouping.

## Summary

**Width topology of authenticated screens.** There is no site-wide container width token. Every page sets `max-width` in its own root `<section>` element via inline `style=` (no `max-w-*` Tailwind utilities are used in templates). The values cluster into three tiers:

| Tier | Value | Pages |
|---|---|---|
| Studio | `1120px` | `projects/show` (the only widest page) |
| Standard | `720px` | `projects/index`, `projects/new` |
| Narrow form | `420–480px` | every Devise screen (sessions, registrations, passwords) |
| Marketing | `1280px` | `home/index` only (anonymous-only via `.marketing-shell` class) |

The top nav (`.app-nav-inner`) and the layout's two flash strips are independently pinned at `1120px` (one CSS class, two inline styles). They do **not** read from any shared variable; the four occurrences of the literal `1120` are unrelated edits that happen to agree.

**Project show topology.** The `<section style="max-width: 1120px">` at `app/views/projects/show.html.erb:1` wraps a single `turbo_stream_from @project` subscription that carries every broadcast for the page. Inside is one CSS grid (`grid lg:grid-cols-2 gap-6`) with two columns:

- **Left column** (the Build section in the user's mental model): in-flight revisions list, messages feed (mixed `Message` rows + `Instruction` status rows ordered by timestamp), and the message composer form.
- **Right column** (sticky on `lg+`): the Preview pane stacked above the GitHub Export pane with a 16-px gap, both in the same `lg:sticky lg:top-4 lg:h-fit` container.

There are no turbo *frames* on the left column — it is driven entirely by stream broadcasts targeting plain DOM ids. The right column has one turbo frame, `github_export_pane`, used so the export form can submit synchronously and replace itself; the preview pane is a plain `div#preview` updated by broadcasts. The `Project` model carries two state-machine `enum` columns — `preview_state` (stopped/starting/running/failed) and `export_state` (not_exported/exporting/exported/failed) — that drive the right-column partials.

**No prior tab decision exists.** The thoughts archive contains zero references to tab navigation, sub-view routing, or grouping the project show page into named sections. The page has accumulated content (revision list → messages → preview pane → export pane) by stacking it inside the existing two-column grid. The `1120px` figure itself does not appear in the archive — plans wrote `max-w-7xl` (Tailwind's 1280px), but the shipped code uses inline `max-width: 1120px`. The hifumi `一 hi · 二 fu · 三 mi` (describe → build → run) pipeline label is currently a marketing-page concept (`docs/02-architecture/04-design-system.md:26-30`), not applied to the studio.

## Detailed Findings

### Layout file — single shared shell for everyone

`app/views/layouts/application.html.erb` is the only top-level layout for the web app (the other layouts under `app/views/layouts/` are mailer-only).

- `<body class="app-shell">` (line 27) — `.app-shell` is defined at `app/assets/tailwind/application.css:182-187`. It sets `min-height: 100vh; background: var(--bg); display: flex; flex-direction: column`. No `max-width`.
- Top nav (lines 28-40) renders **only when `user_signed_in?`** — anonymous users see no nav at all. The nav itself is `<nav class="app-nav">` (sticky, height 60px, hairline bottom border; CSS:189-196), with an inner `<div class="app-nav-inner">` capped at **`max-width: 1120px; margin: 0 auto; padding: 0 24px`** (CSS:197-208).
- `<main class="w-full" style="padding: 24px;">` (line 42) — main element is full-viewport-width with 24-px padding on all sides. **No `max-width` on `<main>`.** Every page constrains its own width via its root `<section>`.
- Flash strips (lines 43-58) are inlined directly in the layout (no partial). Each strip carries `style="max-width: 1120px; margin: 0 auto 16px;"` inline. There are exactly two strips: `.notice-strip--ok` for `:notice` (line 44) and `.notice-strip--err` for `:alert` (line 52).

There is no shared header partial, breadcrumb partial, or top-nav partial — the nav is rendered inline.

### Per-page width values (every authenticated page)

Every authenticated page's outermost element is a `<section>` with width set inline. No view template uses `max-w-*` Tailwind utilities for page width — only inline `style` attributes.

- `app/views/projects/show.html.erb:1` — `<section style="max-width: 1120px; margin: 0 auto;">` (the studio; the only 1120-px page)
- `app/views/projects/index.html.erb:1` — `<section style="max-width: 720px; margin: 0 auto;">`
- `app/views/projects/new.html.erb:1` — `<section style="max-width: 720px; margin: 0 auto;" data-controller="suggestions">`
- `app/views/devise/registrations/edit.html.erb:1` — `<section style="max-width: 480px; margin: 0 auto;">` (and again at lines 69 and 92 for the GitHub-connection and danger-zone sub-sections)
- `app/views/devise/registrations/new.html.erb:1` — `<section style="max-width: 480px; margin: 0 auto;">`
- `app/views/devise/sessions/new.html.erb:1` — `<section style="max-width: 420px; margin: 0 auto;">`
- `app/views/devise/passwords/new.html.erb:1` — `<section style="max-width: 420px; margin: 0 auto;">`
- `app/views/devise/passwords/edit.html.erb:1` — `<section style="max-width: 420px; margin: 0 auto;">`
- `app/views/devise/confirmations/new.html.erb` and `app/views/devise/unlocks/new.html.erb` — **no `<section>` wrapper at all.** These two are still the unstyled Devise defaults: bare `<h2>` and `<div class="field">` children. They never received the hifumi treatment.
- `app/views/home/index.html.erb:1` — `<section class="marketing-shell">` (anonymous-only). `.marketing-shell` at `app/assets/tailwind/application.css:665-669` sets `max-width: 1280px; margin: 0 auto; padding: 0 24px`.

### Where `1120` lives — four independent occurrences

A repo-wide search for the literal `1120` returns exactly four hits, none of which read from a shared variable:

1. `app/assets/tailwind/application.css:198` — `.app-nav-inner { max-width: 1120px; }` (top nav)
2. `app/views/layouts/application.html.erb:44` — inline on the `:notice` flash strip
3. `app/views/layouts/application.html.erb:52` — inline on the `:alert` flash strip
4. `app/views/projects/show.html.erb:1` — inline on the studio's outermost `<section>`

Hifumi defines no width-related CSS custom property (`--accent`, `--paper-*`, `--ink-*`, `--radius-*`, etc. are color/type/radius/easing only — no `--container`, `--page-max`). There is no Tailwind config file and no `@theme` block in the CSS. The CSS top is just `@import "tailwindcss"` followed by a `:root {}` block of design tokens.

### Other CSS width constraints in the design system

`app/assets/tailwind/application.css` has only a handful of width-related rules beyond the four `1120px` hits:

- `.marketing-shell` (lines 665-669) — `max-width: 1280px` (home only)
- `.hero` (lines 670-677) — `max-width: 720px` (home hero text)
- `.msg-bubble` (lines 534-540) — `max-width: 80%` (chat bubble)
- `.preview-frame` (lines 654-660) — `width: 100%; height: 600px` (the iframe)
- `@media (max-width: 720px)` — three uses, collapsing `.revision-row` and `.pipeline` from grid to single column

### Project show — section topology, partials, and broadcast wiring

`app/views/projects/show.html.erb` (46 lines):

```
<section style="max-width: 1120px; margin: 0 auto;">          [line 1]
  turbo_stream_from @project                                    [line 2]   ← single subscription for ALL broadcasts on this page
  eyebrow "studio" + h1 (project.title)                         [lines 4–7]
  render "shared/chat_notice"                                   [line 9]   ← #chat_notice; LLM error banner
  <div class="grid lg:grid-cols-2 gap-6">                       [line 11]
    LEFT  <div class="flex flex-col">                           [line 12]   ← Build
    RIGHT <div class="lg:sticky lg:top-4 lg:h-fit">             [line 39]   ← Preview + Export, stacked
  </div>
</section>
```

The two-column behavior collapses to a single column below the `lg` breakpoint (1024px). Right column is sticky to the viewport top with `lg:sticky lg:top-4 lg:h-fit` only at `lg+`.

#### Left column — Build (chat + revisions + form)

- `<div id="active_revisions">` (line 13) → renders `revisions/list` with `@active_revisions`. Each revision row has its own DOM id `revision_<id>`.
- `<div id="messages" class="flex flex-col" style="gap:12px">` (line 16) → iterates `@chat_events` (Messages and Instructions interleaved by timestamp), rendering either `messages/message` (id `message_<id>`) or `instructions/status_row` (id `instruction_<id>_status`).
- Inline `flash[:alert]` strip (lines 26-33).
- `<div style="margin-top: 16px;">` wrapping `messages/form` (line 35) → composer; root id `project_<id>_message_form`.

`ProjectsController#show` (`app/controllers/projects_controller.rb:30-33`) builds these via two private helpers:

- `active_revisions_for` (lines 49-54) — finds the most recent instruction not in `[completed, failed, cancelled]` and returns its revisions ordered by position.
- `build_chat_events` (lines 56-62) — merges `project.chat.messages.includes(:tool_calls)` (sorted by `created_at`) with `project.instructions.where(phase: %w[completed failed])` (sorted by `updated_at`).

`MessagesController#create` (`app/controllers/messages_controller.rb:4-22`) responds to a successful POST with `turbo_stream.replace("project_<id>_message_form", partial: "messages/form")` (line 19) — does not redirect (per the project-form-replace-over-redirect convention).

#### Right column top — Preview pane

- `app/views/previews/_pane.html.erb` — root `<div id="preview" class="preview-pane">` (line 1). `.preview-pane` (CSS:596-600) sets a 1-px hairline border, `--radius-md` corner, `--paper-0` background, `overflow: hidden`.
- The pane delegates to `PreviewsHelper#preview_pane_partial(project)` (`app/helpers/previews_helper.rb:2-9`) which returns one of four partials based on `project.preview_state`:
  - `previews/_stopped.html.erb` — eyebrow + `tag--stopped` pill + "Start preview" `button_to`
  - `previews/_starting.html.erb` — `tag--starting` pill (blinking dot) + status text
  - `previews/_running.html.erb` — external link to `project.preview_url` + `tag--running` pill + "Stop" `button_to` + `<iframe sandbox="allow-same-origin allow-scripts allow-forms" src="...">`
  - `previews/_failed.html.erb` — `tag--failed` pill + error text + optional `<pre>` with error output + "Retry" button
- `Project` declares `enum :preview_state` at `app/models/project.rb:17-22`: `{stopped: 0, starting: 1, running: 2, failed: 3}`.
- `PreviewsController#create` (`app/controllers/previews_controller.rb:4-23`) and `#destroy` (lines 25-37) both respond with `turbo_stream.replace("preview", partial: "previews/pane")`.
- Async broadcasts come from `Preview::PreviewManager#broadcast` (`lib/preview/preview_manager.rb:325-332`) which calls `Turbo::StreamsChannel.broadcast_replace_to(project, target: "preview", partial: "previews/pane")`. Fired three times in `#start` (lines 39, 54, 84) and once in `#stop`.

**No turbo frame on the preview pane** — `#preview` is a plain `<div>` id, replaced by stream broadcasts.

#### Right column bottom — GitHub Export pane

- Wrapped in `<div style="margin-top: 16px;">` (`show.html.erb:41`) which renders `github_exports/pane`.
- `app/views/github_exports/_pane.html.erb` — root `<%= turbo_frame_tag "github_export_pane" %>` (line 1). **This is the only turbo frame on the show page.**
- The pane has a header (eyebrow "github" + state pill via `_state_tag.html.erb` rendering `tag--stopped|starting|running|failed`) and a body that switches on `project.export_state.to_sym`:
  - `:not_exported` — if `exportable?`, render `_form.html.erb` (form scoped to `:github_export`, target frame `github_export_pane`); else show the "connect GitHub first" CTA.
  - `:exporting` — "Exporting to GitHub…" status.
  - `:exported` — link to `project.github_repo_url`, plus "Push latest changes" or "Create a new repository" `button_to`s targeting the same frame.
  - `:failed` — error text + optional `<pre>` with `export_error` + "Retry" button.
- `Project` declares `enum :export_state` at `app/models/project.rb:24-29`: `{not_exported: 0, exporting: 1, exported: 2, failed: 3}`. `Project#exportable?` (lines 36-40) requires `github_connection.connected?`, at least one completed instruction, and `!export_exporting?`.
- `GithubExportsController#create` (`app/controllers/github_exports_controller.rb:4-25`) and `#destroy` (lines 33-41) both render `partial: "github_exports/pane"` directly — the turbo frame swaps it.
- Async broadcasts come from `ExportToGithubJob#broadcast` (`app/jobs/export_to_github_job.rb:108-115`) calling `Turbo::StreamsChannel.broadcast_replace_to(project, target: "github_export_pane", partial: "github_exports/pane")`. Fired at lines 22, 32, and 103 (the `fail!` path).

#### Single-channel broadcast map

`turbo_stream_from @project` (line 2) is the only Action Cable subscription on the page. Every section receives updates through it.

| DOM id | Kind | Section | Sources that broadcast to it |
|---|---|---|---|
| `chat_notice` | div | Build | `ChatRespondJob#broadcast_chat_notice` (`chat_respond_job.rb:62-69`) on LLM error |
| `active_revisions` | div | Build | `event_subscribers.rb:13-18` (`instruction.requested`); :50-55 (`instruction.completed`); :109-114 (`instruction.failed`) |
| `messages` (append) | div | Build | `Message#after_create_commit → broadcast_append_message` (`message.rb:5,16-23`); `event_subscribers.rb:44-49`/`:103-108` append `instructions/status_row` |
| `message_<id>` (replace) | div | Build | `Message#after_update_commit → broadcast_replace_message` (`message.rb:6,26-33`); `ChatRespondJob#broadcast_replace` during streaming (`chat_respond_job.rb:75-82`); `ToolCall#after_commit → touch_message` (`tool_call.rb:13-18`) which fires the Message replace |
| `revision_<id>` (replace) | div | Build | `event_subscribers.rb:31-39` on `revision.started/completed/failed` |
| `project_<id>_message_form` | div | Build | `MessagesController#create` response |
| `preview` (replace) | div | Preview | `PreviewManager#broadcast` (`preview_manager.rb:325-332`); `PreviewsController` create/destroy responses |
| `github_export_pane` (replace) | **turbo frame** | Export | `ExportToGithubJob#broadcast` (`export_to_github_job.rb:108-115`); `GithubExportsController` create/destroy responses |

### Side-by-side grid breakpoint

`grid lg:grid-cols-2 gap-6` at `show.html.erb:11` — Tailwind's `lg:` prefix is `≥1024px`. Below that the grid collapses to one column (Tailwind's default for `grid` without a column count). Both columns are equal `1fr` halves; no fixed widths or percentages. The preview iframe inside the right column stretches to `width: 100%` via `.preview-frame`.

## Code References

- `app/views/layouts/application.html.erb:27` — `<body class="app-shell">`
- `app/views/layouts/application.html.erb:28-40` — top nav, only when `user_signed_in?`
- `app/views/layouts/application.html.erb:42` — `<main class="w-full" style="padding: 24px;">`
- `app/views/layouts/application.html.erb:44,52` — flash strips with inline `max-width: 1120px`
- `app/assets/tailwind/application.css:182-187` — `.app-shell`
- `app/assets/tailwind/application.css:189-196` — `.app-nav`
- `app/assets/tailwind/application.css:197-208` — `.app-nav-inner` (1120 px max-width)
- `app/assets/tailwind/application.css:596-600` — `.preview-pane` (border, radius, paper-0 background)
- `app/assets/tailwind/application.css:654-660` — `.preview-frame` (iframe sizing)
- `app/assets/tailwind/application.css:665-669` — `.marketing-shell` (1280 px)
- `app/views/projects/show.html.erb:1-46` — studio entry point
- `app/views/projects/show.html.erb:11` — `grid lg:grid-cols-2 gap-6`
- `app/views/projects/show.html.erb:39` — `lg:sticky lg:top-4 lg:h-fit` right column
- `app/views/projects/show.html.erb:40-42` — preview + export panes stacked
- `app/views/previews/_pane.html.erb:1-2` — `<div id="preview" class="preview-pane">` + helper dispatch
- `app/views/github_exports/_pane.html.erb:1` — `turbo_frame_tag "github_export_pane"`
- `app/helpers/previews_helper.rb:2-9` — `preview_pane_partial`
- `app/models/project.rb:17-22` — `enum :preview_state`
- `app/models/project.rb:24-29` — `enum :export_state`
- `app/models/project.rb:36-40` — `exportable?`
- `app/controllers/projects_controller.rb:30-33,49-54,56-62` — `#show`, `active_revisions_for`, `build_chat_events`
- `app/controllers/previews_controller.rb:4-23,25-37` — preview create/destroy
- `app/controllers/github_exports_controller.rb:4-25,33-41` — export create/destroy
- `app/controllers/messages_controller.rb:4-22` — message create + form-replace
- `lib/preview/preview_manager.rb:325-332,39,54,84` — preview broadcasts
- `app/jobs/export_to_github_job.rb:108-115,22,32,103` — export broadcasts
- `app/jobs/chat_respond_job.rb:62-69,75-82` — chat-notice + streaming replace
- `config/initializers/event_subscribers.rb:13-18,31-39,44-49,50-55,103-108,109-114` — instruction/revision broadcasts

## Architecture Documentation

- **Width is per-view, not centralized.** Every page's outermost `<section>` carries an inline `style="max-width: …; margin: 0 auto;"`. The hifumi design system defines no width tokens; `application.css` exposes only color, typography, radius, shadow, and easing custom properties.
- **The 1120-px figure is repeated in four uncoupled places.** `.app-nav-inner` (CSS), the two flash strips (inline in layout), and the studio section (inline in `show.html.erb`). Changing one does not change the others.
- **Three width tiers in use today** for authenticated content: `1120px` (studio only), `720px` (project list/new), `420–480px` (Devise forms). The top nav and flash strips are always `1120px` regardless of which page is showing — when the user is on a 480-px Devise page, the nav and any flash above the page content are still 1120-px wide and may visually misalign with the content section.
- **Project show is a single 1120-px section with a two-column grid inside.** The grid is Tailwind-only (`grid lg:grid-cols-2 gap-6`); columns are equal halves with no explicit width.
- **One Action Cable subscription per project** (`turbo_stream_from @project` at `show.html.erb:2`) carries all updates for the three sections. Targets are mostly plain DOM ids; only the GitHub-export pane is a turbo frame (so it can absorb form submissions synchronously).
- **State is stored on the Project**, not on a separate per-section model: `preview_state` and `export_state` enums on `Project` drive the right-column partials.
- **Devise `confirmations/new` and `unlocks/new` are still default Rails-generated views** with no hifumi `<section>`/eyebrow treatment. Other Devise views were converted in the 2026-05-08 plan (`thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md`) but these two were not in scope.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-04-18/phase-2-step-3-chat-baseline.md:161` — Phase 2 Step 3 plan established the studio as a single chat column with `<section class="w-full max-w-3xl mx-auto">`.
- `thoughts/shared/plans/2026-04-21/phase-2-step-6-events-turbo-revisions.md:165` — Phase 2 Step 6 retained `max-w-3xl`.
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:973,978-996,1055` — Phase 3 widened the studio to **`max-w-7xl`** in the plan and specified the exact `grid lg:grid-cols-2 gap-6` markup with `lg:sticky lg:top-4 lg:h-fit` on the right column. Manual verification on project 38 confirmed the split shipped. **The shipped code uses inline `max-width: 1120px`**, not `max-w-7xl` (1280 px) — the implementation diverged from the plan; no follow-up note documents the change.
- `thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md:183-191` — confirms that as of Phase 2 close, the studio was a single `max-w-3xl` column with no preview/iframe/pill.
- `thoughts/shared/plans/2026-05-07/github-export-prototype.md:828-836` — the export prototype plan placed the export pane below the preview pane in the same right-column sticky container, intentionally not as a separate route or tab.
- `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md` — the 2026-05-08 Devise restyling plan documented the per-Devise-view widths (420 px for short forms, 480 px for sign-up/account-edit) and the three-section layout of `registrations/edit`. It did not propose unifying width across screens.
- `docs/01-vision/02-user-journey.md:420` — vision canon: "split view: chat + iframe" is in the canon from the start.
- `docs/02-architecture/04-design-system.md:26-30` — the `一 hi · 二 fu · 三 mi` (describe → build → run) pipeline is currently scoped to the marketing/home page.
- **No archive document discusses tab navigation, sub-view routing, or named section grouping on the project show page.** No archive document references the `1120px` value.

## Related Research

- `thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md` — Phase 3 kickoff (pre-split layout state)
- `thoughts/shared/research/2026-05-08/users-edit-unstyled.md` — earlier same-day research on the unstyled Devise account-edit page
- `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md` — the Devise restyling plan that landed `ac49b26`, `898d6e7`, `d6f1629`, `e74581e`

## Open Questions

- Whether the broadcast model (one `turbo_stream_from @project` updating ids across all three sections) needs adaptation if a tab UI hides two of the three sections at any moment — hidden tabs still receive broadcasts because the DOM ids remain in the document; this is a property to confirm rather than design from scratch.
- Why the implementation switched from the planned `max-w-7xl` to inline `max-width: 1120px` is not documented in the archive.
- The unstyled `app/views/devise/confirmations/new.html.erb` and `app/views/devise/unlocks/new.html.erb` are out of scope of the most recent Devise plan and remain at default Rails markup with no `<section>` wrapper or `max-width`.
