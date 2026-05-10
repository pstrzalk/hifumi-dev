---
date: 2026-05-11T00:56:31+0200
researcher: Paweł Strzałkowski
git_commit: 0c724e40a8ac218bd18e93ae6bf2630c40084418
branch: main
repository: rails-app-generator
topic: "Projects list — current row anatomy, vertical metrics, and data already available per row"
tags: [research, codebase, projects-index, project-card, hifumi, design-system]
status: complete
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Research: Projects list — current row anatomy, vertical metrics, and data already available per row

**Date**: 2026-05-11T00:56:31+0200
**Researcher**: Paweł Strzałkowski
**Git Commit**: 0c724e40a8ac218bd18e93ae6bf2630c40084418
**Branch**: main
**Repository**: rails-app-generator

## Research Question

> projects list, it should be twice as high, we can also use a bigger vertical gap between items on the list. if more info is possible, we may add something (but we don't have to)

Document the current implementation of the projects list — markup, CSS, vertical metrics, and what `Project` data is already available to potentially surface on a row.

## Summary

The projects list lives in a single ERB template (`app/views/projects/index.html.erb`) backed by `ProjectsController#index`. Each project is rendered as a `<li class="project-card project-card--<state>">` styled by hand-written CSS classes in `app/assets/tailwind/application.css:467-534`. There is no shared partial — the entire row template and the empty-state card both live inline in `index.html.erb`.

A row is a 3-column CSS grid (`4px 1fr auto`): a status stripe, a body, and an action area. Vertical size of a row is **not** set by any `height` or `min-height` rule; it falls out entirely from `.project-card__body`'s `padding: 12px 14px` plus its two stacked text rows (name at `font-size: 22px`, meta at `font-size: 18px`). The list `<ul>` uses an inline `gap: 10px` to separate rows.

Each row currently surfaces four pieces of data: `project.name` (link), `project.preview_state` (twice — as stripe color and as a `.tag` label), and a relative-time string built from `project.created_at`, plus a delete `button_to`. The `projects` table holds several more fields that are not currently rendered (export state, GitHub repo full name, preview started-at, updated-at, preview error, etc.), and the `Project` model exposes derived helpers (`preview_url`, `github_repo_url`, `exportable?`, `workspace_initialized?`) that pull from existing columns.

## Detailed Findings

### Controller — what the index loads

`app/controllers/projects_controller.rb:5-7`

```ruby
def index
  @projects = current_user.projects.order(created_at: :desc)
end
```

- Single query, ordered by `created_at DESC`.
- No `includes` / preloading — anything that touches `instructions`, `revisions`, or `chat` from the view would be N+1.
- No counts, no scopes, no decorator.

### View — `app/views/projects/index.html.erb`

Full file, 43 lines. The list block is lines 10-29:

```erb
<% if @projects.any? %>
  <ul class="flex flex-col" style="gap: 10px; padding: 0; margin: 0; list-style: none;">
    <% @projects.each do |project| %>
      <li class="project-card project-card--<%= project.preview_state %>">
        <div class="project-card__stripe"></div>
        <div class="project-card__body">
          <%= link_to project.name, project, class: "project-card__name" %>
          <div class="project-card__meta">
            <span class="tag tag--<%= project.preview_state %>"><%= project.preview_state %></span>
            <span class="dot">·</span>
            <span>created <%= time_ago_in_words(project.created_at) %> ago</span>
          </div>
        </div>
        <div class="project-card__actions">
          <%= button_to "delete", project, method: :delete,
                form: { data: { turbo_confirm: "Delete \"#{project.name}\"?" } } %>
        </div>
      </li>
    <% end %>
  </ul>
<% else %>
  <div class="project-card" style="padding: 0;">
    <div class="project-card__stripe"></div>
    <div class="project-card__body" style="padding: 24px;">
      <p style="margin: 0; color: var(--fg-muted);">
        No projects yet.
        <%= link_to "Create your first one", new_project_path,
            style: "color: var(--accent); text-decoration: underline; text-underline-offset: 2px;" %>.
      </p>
    </div>
    <div></div>
  </div>
<% end %>
```

Outer section caps width at `1600px`. List `<ul>` controls inter-row spacing via inline `gap: 10px` (line 11). Header line above the list uses `.eyebrow` + `.h-section` (lines 4-5) with `margin-bottom: 24px`.

The `preview_state` value is rendered **twice per row** — once as a CSS modifier on the `<li>` (drives the stripe color) and once as a textual `.tag` inside the meta line.

### CSS — `app/assets/tailwind/application.css:467-534`

Block boundary comment on line 467-469:

```css
/* ============================================================
   PROJECT CARD — outlined, status stripe + mono tag
   ============================================================ */
```

Grid + container:

```css
.project-card {
  display: grid;
  grid-template-columns: 4px 1fr auto;
  align-items: stretch;
  background: var(--paper-0);
  border: 1px solid var(--border);
  text-decoration: none;
  color: inherit;
}
.project-card__stripe { background: var(--ink-200); }
```

Body (the only thing that contributes to row height):

```css
.project-card__body {
  padding: 12px 14px;
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 0;
}
.project-card__name {
  font-family: var(--hi-font-mono);
  font-weight: 500;
  font-size: 22px;
  color: var(--ink-800);
  letter-spacing: -0.01em;
  text-decoration: none;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.project-card__meta {
  display: flex;
  align-items: center;
  gap: 10px;
  font-family: var(--hi-font-mono);
  font-size: 18px;
  color: var(--fg-muted);
}
```

Actions column:

```css
.project-card__actions {
  display: flex;
  align-items: stretch;
  border-left: 1px solid var(--border);
}
.project-card__actions form,
.project-card__actions button { display: flex; align-items: center; }
.project-card__actions button {
  background: transparent;
  border: 0;
  cursor: pointer;
  font-family: var(--hi-font-mono);
  font-size: 18px;
  text-transform: uppercase;
  letter-spacing: 0.14em;
  color: var(--fg-muted);
  padding: 0 16px;
}
.project-card__actions button:hover { color: var(--accent); background: var(--bg-elevated); }
```

State-driven stripe colors:

```css
.project-card--running  .project-card__stripe { background: var(--ok-line); }
.project-card--starting .project-card__stripe { background: var(--info-fg); }
.project-card--stopped  .project-card__stripe { background: var(--ink-300); }
.project-card--failed   .project-card__stripe { background: var(--accent); }
```

The stripe spans the full row height automatically because the grid uses `align-items: stretch`.

### Current vertical metrics (what determines "row height")

Nothing sets an explicit `height` / `min-height` on the card. Effective row height is built from:

| Source | Value |
| --- | --- |
| `.project-card__body` vertical padding (top + bottom) | 12 + 12 = **24px** |
| Name line (`font-size: 22px`, mono, line-height defaults from `body`) | ~28-30px |
| Inner gap between name and meta | **6px** |
| Meta line (`font-size: 18px`, mono) | ~22-24px |
| **Approx row height** | **~80-86px** |
| Inter-row gap (`<ul>` inline `gap`) | **10px** |

The tag inside the meta has `padding: 3px 8px; line-height: 1` (`app/assets/tailwind/application.css:442-446`) so it does not significantly raise the meta line height.

### Tag / status taxonomy used in the meta line

`.tag` and its state modifiers (`app/assets/tailwind/application.css:433-456`):

- `.tag--pending` → `--fg-faint`
- `.tag--gen` → `--info-fg`
- `.tag--ok` → `--ok-line`
- `.tag--err` → `--accent`
- `.tag--running` → `--ok-line`
- `.tag--starting` → `--info-fg`
- `.tag--stopped` → `--fg-muted`
- `.tag--failed` → `--accent`

The card's tag is keyed off `project.preview_state` only (one of: `stopped / starting / running / failed`). No tag is shown for `export_state` or for in-flight generation.

### Header above the list

`app/views/projects/index.html.erb:2-8`

```erb
<div class="flex items-baseline justify-between" style="margin-bottom: 24px;">
  <div>
    <div class="eyebrow">projects · index</div>
    <h1 class="h-section" style="margin-top: 4px;">Your projects</h1>
  </div>
  <%= link_to "+ New project", new_project_path, class: "btn btn--primary btn--sm" %>
</div>
```

`.h-section` is `font-size: 40px` sans (`application.css:133-140`); `.eyebrow` is `font-size: 18px` mono caps (`application.css:155-162`).

### Project model — fields/methods available without extra queries

`app/models/project.rb` exposes columns and helpers any list row could read (no joins needed, all per-project):

Columns (from `db/schema.rb:131-146`):

- `name` (string, not null) — currently shown
- `created_at`, `updated_at` (datetimes, not null) — only `created_at` is currently shown
- `preview_state` (enum int: stopped / starting / running / failed) — currently shown
- `preview_container_id` (string, nullable)
- `preview_error` (text, nullable)
- `preview_started_at` (datetime, nullable)
- `export_state` (enum int: not_exported / exporting / exported / failed)
- `exported_at` (datetime, nullable)
- `export_error` (text, nullable)
- `github_repo_full_name` (string, nullable, unique index)
- `user_id` (int, not null)

Derived methods on `Project` (`app/models/project.rb`):

- `github_repo_url` → `"https://github.com/#{github_repo_full_name}"` (returns `nil` if blank). Line 31-34.
- `preview_url` → returns a URL only when `preview_running?`, picks between `https://<id>.preview.<domain>` (remote) and `http://localhost:<port>` (local). Line 49-57.
- `preview_port` → `Preview::Config.port_offset + id`. Line 59-61.
- `workspace_initialized?` → filesystem `File.exist?` check — would touch disk per row. Line 63-65.
- `exportable?` → composite check that hits `user.github_connection` and `instructions.where(phase: :completed).exists?` — extra queries, would N+1 from a list. Line 36-40.
- `current_state_prompt` → loads the active instruction + counts revisions; would N+1 from a list. Line 70-79.

Associations (would require preloading to use from a list):

- `has_one :chat`
- `has_many :instructions`
- `has_many :revisions`

The `Instruction` model has `phase` enum: `researching / planning / implementing / completed / failed / cancelled` (`app/models/instruction.rb:6-13`). The "is a generation currently running for this project?" predicate is implemented inline in `Project#current_state_prompt` as "any instruction whose phase is not in `%w[completed failed cancelled]`".

### Data currently rendered per row vs. data sitting unused

Currently rendered:

- `project.name` (link)
- `project.preview_state` — twice (CSS modifier + tag)
- `time_ago_in_words(project.created_at)`
- Delete button

Already on the row's `project` object, not rendered:

- `project.updated_at`
- `project.export_state` and `project.exported_at`
- `project.github_repo_full_name` / `project.github_repo_url`
- `project.preview_url` (live only while running)
- `project.preview_started_at`
- `project.preview_error`, `project.export_error`

Available only via extra queries (would need preloading to avoid N+1):

- Count of instructions / revisions
- "Is generation currently running" (via `instructions.where.not(phase: terminal).exists?`)
- "Has any completed instruction" (used by `exportable?`)
- Last chat message timestamp

### Empty state

`index.html.erb:30-42` — re-uses the `.project-card` shell with inline `padding: 0` and a body padding override (`24px`). No list iteration, no gap, no count. The empty-state card has a stripe but no `--<state>` modifier, so the stripe takes the default `--ink-200` grey.

## Code References

- `app/views/projects/index.html.erb:1-43` — entire projects-list template (header + list + empty state)
- `app/views/projects/index.html.erb:11` — inline `gap: 10px` between rows
- `app/views/projects/index.html.erb:13-27` — row markup template
- `app/views/projects/index.html.erb:18-20` — meta line (tag + dot + created-ago)
- `app/views/projects/index.html.erb:23-26` — actions column with `button_to` delete
- `app/controllers/projects_controller.rb:5-7` — `#index` action: `current_user.projects.order(created_at: :desc)`, no preloads
- `app/assets/tailwind/application.css:467-534` — entire `.project-card*` ruleset
- `app/assets/tailwind/application.css:470-478` — grid container (no height set)
- `app/assets/tailwind/application.css:480-486` — body padding `12px 14px`, inner `gap: 6px`
- `app/assets/tailwind/application.css:487-498` — name typography (`font-size: 22px`, mono)
- `app/assets/tailwind/application.css:499-507` — meta typography (`font-size: 18px`, mono)
- `app/assets/tailwind/application.css:508-529` — actions column + button
- `app/assets/tailwind/application.css:531-534` — state-stripe color modifiers
- `app/assets/tailwind/application.css:433-465` — `.tag` ruleset + blinking `.tag-dot` keyframes (not used on the projects list)
- `app/models/project.rb:17-22` — `preview_state` enum (stopped / starting / running / failed)
- `app/models/project.rb:24-29` — `export_state` enum (not_exported / exporting / exported / failed)
- `app/models/project.rb:31-89` — derived helpers (`github_repo_url`, `preview_url`, `preview_port`, `workspace_initialized?`, `exportable?`, `current_state_prompt`)
- `app/models/instruction.rb:6-13` — `phase` enum used to detect "generation running"
- `db/schema.rb:131-146` — `projects` table column list

## Architecture Documentation

- The projects list is the only place `.project-card*` is used in the codebase (grep confirms references only inside `app/views/projects/index.html.erb` and `app/assets/tailwind/application.css`). There is no row partial; the row template is inline in `index.html.erb`.
- CSS lives in the single Hifumi tokens-and-components stylesheet `app/assets/tailwind/application.css` per `CLAUDE.md` ("All visible chrome ... follows the Hifumi design system applied 2026-05-01. Tokens + component classes live in a single file: `app/assets/tailwind/application.css`").
- Status visualization uses two parallel channels: a 4px colored stripe (`.project-card__stripe`, state-keyed on `preview_state`) and a rectangular outlined `.tag` (state-keyed on `preview_state`). The `.tag-dot` blinking-dot variant exists (`application.css:458-465`) and is used elsewhere for live states, but not on the projects list.
- Row height is purely intrinsic — driven by body padding plus the two-line stacked content (`name` + `meta`). No `height`/`min-height` constraint exists on `.project-card`. The stripe column uses `align-items: stretch` so it naturally grows with whatever determines body height.
- Inter-row spacing is set inline on the `<ul>` (`gap: 10px`), not via a `.project-card`-side class. The list `<ul>` carries layout-only utility classes (`flex flex-col`) plus the inline `gap`/list resets.
- `ProjectsController#index` returns all projects without preloading associations, so any extra information added to the row template that traverses `instructions`, `revisions`, or `chat` would N+1. Existing model methods `exportable?` and `current_state_prompt` already trigger such queries internally.

## Historical Context (from thoughts/)

The Hifumi design system (which `.project-card`, `.tag`, `.eyebrow`, `.h-section` belong to) was rolled out 2026-05-01 per `CLAUDE.md`. Recent UI research in the same neighborhood:

- `./thoughts/shared/research/2026-05-09/typography-font-size-inventory.md` — typography ramp inventory across views (likely covers `.project-card__name`, `.project-card__meta`, `.eyebrow`).
- `./thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md` — studio surfaces (folder cards + bubbles) lifted onto `--paper-0`; same paper/border treatment is used by `.project-card`.
- `./thoughts/shared/research/2026-05-09/studio-composer-multiline-and-sticky.md` — studio composer multiline + sticky dock work (different surface; not the projects list).
- `./thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` — phase 3 preview lifecycle plan; explains why `preview_state` exists and why `preview_url` is only meaningful while running.

`docs/02-architecture/04-design-system.md` is the canonical Hifumi token/component inventory per `CLAUDE.md`.

## Related Research

- `./thoughts/shared/research/2026-05-09/typography-font-size-inventory.md`
- `./thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md`
- `./thoughts/shared/research/2026-05-09/studio-composer-multiline-and-sticky.md`

## Open Questions

- Should the second piece of info (if added) come from data already on `Project` columns (no preload cost — e.g. `updated_at`, `github_repo_full_name`, `exported_at`, `preview_url`) or from associations like "active instruction" / "revisions count" (would require `ProjectsController#index` to add an `includes` or counter)?
- Should the row's status channel continue to key only on `preview_state`, or also reflect generation state (active `Instruction` phase) and/or export state?
- Is the list expected to support row-level affordances beyond delete (e.g. open preview, open repo, "continue generating") that would justify a taller row?
