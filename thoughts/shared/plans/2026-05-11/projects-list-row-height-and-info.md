---
date: 2026-05-11
planner: Paweł Strzałkowski
git_commit: 0c724e40a8ac218bd18e93ae6bf2630c40084418
branch: main
repository: rails-app-generator
topic: "Projects list — taller rows, larger gap, third line with affordances"
tags: [plan, projects-index, project-card, hifumi, design-system]
status: ready
---

# Projects list — taller rows + third info line Implementation Plan

## Overview

Make each row in the projects list ≈1.75× its current height by adding a third line of useful information beneath the existing meta line, and increase the inter-row gap. The new line surfaces affordances and signals that are already columns on `Project` — no controller changes, no new queries.

## Current State Analysis

See `thoughts/shared/research/2026-05-11/projects-list-row-height-and-info.md` for the full anatomy. Summary:

- Row height ≈80-86 px, driven entirely by `.project-card__body`'s `padding: 12px 14px` + name (22 px mono) + 6 px inner gap + meta (18 px mono). No `height` / `min-height` set anywhere.
- Inter-row spacing: inline `gap: 10px` on the `<ul>` (`app/views/projects/index.html.erb:11`).
- Row content: name → [tag · "created X ago"] · delete-button. State stripe (4 px) keyed on `preview_state`.
- Controller has no `includes`/preloads (`app/controllers/projects_controller.rb:5-7`), so any new field that traverses `instructions`, `revisions`, or `chat` would N+1.
- All `.project-card*` styles live in `app/assets/tailwind/application.css:467-534` (Hifumi single-file model).

## Desired End State

A row is ≈140-150 px tall and shows three stacked lines inside the body:

```
┌─┬──────────────────────────────────────────────────┬────────┐
│ │ my-todo-app                          ← name      │ delete │
│■│ [ RUNNING ] · created 3 days ago     ← line 2    │        │
│ │ active 12m ago · open preview ↗ · github ↗ ← new │        │
└─┴──────────────────────────────────────────────────┴────────┘
```

- Line 1 (`__name`): unchanged.
- Line 2 (`__meta`): unchanged (state tag + "created X ago").
- Line 3 (`__sub`, new): always renders at least `active <updated_at> ago`. Appends `· open preview ↗` (when `preview_running?`), `· github ↗` (when `github_repo_full_name.present?`), `· last error: <truncated 60 chars>` (when `preview_state == "failed"` and `preview_error.present?`).
- Inter-row gap: 20 px (was 10 px). Lives in a new `.project-list` class, not inline.
- Empty state still uses `.project-card` shell; the previously inline `padding: 24px` override is removed because base body padding is now 24 px.

Verification: open `/projects` with a mix of running / stopped / failed / fresh projects and the projects-with-github-repo seed, eyeball that row height roughly doubled, gap is visibly larger, third line shows the right items for each state, and clicking `open preview ↗` opens the live preview URL in a new tab.

### Key Discoveries:

- All fields needed for the new line are columns on `projects` (`db/schema.rb:131-146`) — no joins. Derived helpers `Project#preview_url` (line 49) and `Project#github_repo_url` (line 31) already exist and gate on `preview_running?` / `github_repo_full_name` respectively.
- `.project-card` uses `grid-template-columns: 4px 1fr auto` with `align-items: stretch`, so adding height inside `__body` stretches the stripe and actions column automatically. No layout rework needed.
- The Hifumi design system explicitly lives in the single `application.css` file (per `CLAUDE.md`), using tokens like `--accent`, `--fg-muted`, `--fg-faint`. Don't hardcode hex values, don't add a separate stylesheet.
- The `.tag-dot` blinking-dot pattern (`application.css:458-465`) exists but isn't used on the projects list; this plan does not introduce it.

## What We're NOT Doing

- **No controller change.** `ProjectsController#index` keeps its single, preload-free query. No `includes`, no counter caches.
- **No "generation in progress" signal** (would require traversing `instructions`). The chat panel inside the project already surfaces this.
- **No second status tag** for `export_state`. Export state surfaces only via the optional `github ↗` link (which implies "this is exported and lives on GitHub").
- **No row-level kebab menu / action drawer.** Affordances stay as inline links on the third line; delete stays in the right-hand actions column.
- **No row-link refactor.** Name is the only entry point to the project page; we are not making the whole row clickable.
- **No empty-state redesign.** Only the now-redundant inline padding override is removed.
- **No new partial.** The row markup stays inline in `index.html.erb`. Single use site.
- **No DB migration, no model changes.** Everything plumbs through existing columns and helpers.

## Implementation Approach

Single commit. CSS-side: bump body padding, add a new `__sub` rule, move the `<ul>` inline styles into a `.project-list` class with the new gap. View-side: add the third line with its four conditional pieces, drop the empty-state padding override.

## Phase 1: Bigger row + third info line

### Commit
`design: projects list — taller rows with third info line + larger gap`

### Overview

CSS and ERB changes in two files. No Ruby changes.

### Changes Required:

#### 1. Project card CSS — `app/assets/tailwind/application.css`

**Block to modify**: `app/assets/tailwind/application.css:467-534` (the `.project-card*` block).

**Changes**:
- Add a new `.project-list` class at the top of the project-card block — owns the `<ul>` reset + 20 px gap previously inlined.
- Bump `.project-card__body` padding `12px 14px` → `24px`; inner `gap` `6px` → `8px`.
- Add `.project-card__sub` for the new line: same mono typography as `__meta`, separator dots styled identically, `last error:` text shifts to `var(--accent)`.
- Add `.project-card__sub a` link style: muted by default, accent on hover, no underline (matches Hifumi link treatment on `.project-card__name`).

```css
/* ============================================================
   PROJECT CARD — outlined, status stripe + mono tag
   ============================================================ */
.project-list {
  display: flex;
  flex-direction: column;
  gap: 20px;
  padding: 0;
  margin: 0;
  list-style: none;
}

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
.project-card__body {
  padding: 24px;
  display: flex;
  flex-direction: column;
  gap: 8px;
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
.project-card__name:hover { color: var(--accent); }
.project-card__meta {
  display: flex;
  align-items: center;
  gap: 10px;
  font-family: var(--hi-font-mono);
  font-size: 18px;
  color: var(--fg-muted);
}
.project-card__meta .dot { color: var(--fg-faint); }

.project-card__sub {
  display: flex;
  align-items: center;
  gap: 10px;
  font-family: var(--hi-font-mono);
  font-size: 18px;
  color: var(--fg-muted);
  min-width: 0;
}
.project-card__sub .dot { color: var(--fg-faint); }
.project-card__sub a {
  color: var(--fg-muted);
  text-decoration: none;
}
.project-card__sub a:hover { color: var(--accent); }
.project-card__sub .project-card__error {
  color: var(--accent);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}

.project-card__actions { /* unchanged */ }
/* …rest of existing rules unchanged… */
```

(The `.project-card__actions` block and the `.project-card--<state> .project-card__stripe` state overrides stay byte-for-byte the same.)

#### 2. Index view — `app/views/projects/index.html.erb`

**File**: `app/views/projects/index.html.erb`

**Changes**:
- Replace inline `<ul>` styles with `class="project-list"`.
- Add a `<div class="project-card__sub">` after `__meta` carrying the conditional pieces.
- Drop the inline `padding: 0` on the empty-state `.project-card` and the `padding: 24px` override on its `__body` (base now 24 px).

```erb
<section style="max-width: 1600px; margin: 0 auto;">
  <div class="flex items-baseline justify-between" style="margin-bottom: 24px;">
    <div>
      <div class="eyebrow">projects · index</div>
      <h1 class="h-section" style="margin-top: 4px;">Your projects</h1>
    </div>
    <%= link_to "+ New project", new_project_path, class: "btn btn--primary btn--sm" %>
  </div>

  <% if @projects.any? %>
    <ul class="project-list">
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
            <div class="project-card__sub">
              <span>active <%= time_ago_in_words(project.updated_at) %> ago</span>
              <% if project.preview_running? %>
                <span class="dot">·</span>
                <%= link_to "open preview ↗", project.preview_url, target: "_blank", rel: "noopener" %>
              <% end %>
              <% if project.github_repo_full_name.present? %>
                <span class="dot">·</span>
                <%= link_to "github ↗", project.github_repo_url, target: "_blank", rel: "noopener" %>
              <% end %>
              <% if project.preview_state == "failed" && project.preview_error.present? %>
                <span class="dot">·</span>
                <span class="project-card__error">last error: <%= project.preview_error.truncate(60) %></span>
              <% end %>
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
    <div class="project-card">
      <div class="project-card__stripe"></div>
      <div class="project-card__body">
        <p style="margin: 0; color: var(--fg-muted);">
          No projects yet.
          <%= link_to "Create your first one", new_project_path,
              style: "color: var(--accent); text-decoration: underline; text-underline-offset: 2px;" %>.
        </p>
      </div>
      <div></div>
    </div>
  <% end %>
</section>
```

### Success Criteria:

#### Automated Verification:

- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Index renders without raising on every relevant fixture: `bin/rails test test/controllers/projects_controller_test.rb`
- [ ] Index renders without raising on the system-test level for the rows: `bin/rails test:system` (if the existing system suite already covers `/projects`; otherwise skip — no new system test added by this plan)
- [x] No new SQL queries from rendering the list: with `current_user.projects.count >= 3` in dev, `bin/rails server`, visit `/projects`, confirm the log shows exactly one `SELECT … FROM projects` (the controller query) and no `SELECT … FROM instructions / revisions / chats / users` triggered by the row template

#### Manual Verification:

- [x] Each row is visibly taller than before (eyeball ≈1.75× — was ~80 px, should be ~140-150 px)
- [x] Inter-row gap is clearly larger than before (was 10 px, now 20 px)
- [x] Line 1 (name) and line 2 (state tag + "created X ago") look identical to before
- [x] Line 3 always shows `active X ago` for every project, including fresh ones
- [x] On a `running` project: `· open preview ↗` appears and clicking it opens the live preview in a new tab
- [x] On a project with a connected GitHub repo: `· github ↗` appears and clicking it opens the GitHub repo in a new tab
- [x] On a `failed` project with a `preview_error`: `· last error: <text>` appears, truncated, and is rendered in accent color (`var(--accent)`)
- [x] On a fresh / stopped / no-repo / no-error project: line 3 collapses to just `active X ago` and the row height stays consistent (because line 3 still occupies one line)
- [x] Empty state still renders cleanly with the same dimensions it had before (or marginally larger — body padding moved from inline 24 px to base 24 px, identical)
- [x] Delete button still works and the confirm dialog still shows the project name
- [x] No console warnings, no broken layout at viewport widths down to 1024 px

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation. Single-commit plan — no further phases.

---

## Testing Strategy

### Unit Tests:

No new unit tests. The view change is pure presentation: it reads columns and existing helper methods that already have model-level coverage (`preview_running?`, `preview_url`, `github_repo_url`).

### Integration Tests:

Existing controller test (`test/controllers/projects_controller_test.rb` if present) continues to pass — the view still renders, the action contract is unchanged.

### Manual Testing Steps:

1. Boot dev: `bin/dev` (or `bin/rails server`).
2. Sign in. If you don't have a mix of states, seed: create one running project (start preview), one stopped, one with a connected GitHub repo, and one in `failed` state (kill the container or set `preview_state: :failed` + `preview_error: "Bundle install failed: cannot resolve dependency for rails"` directly in console).
3. Visit `/projects`. Confirm all the items in the manual-verification checklist above.
4. Resize the window down to ~1024 px to verify the third line doesn't wrap awkwardly. If it does, that's an acceptable degradation — the line will wrap and the row will grow.
5. Confirm in dev server logs that the page renders with one `SELECT … FROM projects` and no per-row association queries (no N+1).

## Performance Considerations

- No new queries. Every new value comes from columns already loaded by `current_user.projects.order(created_at: :desc)`.
- `time_ago_in_words(project.updated_at)` is pure Ruby on already-loaded data.
- `Project#preview_running?` is `preview_state == "running"` — in-memory.
- `Project#preview_url` constructs a string from `id` and `preview_state` — in-memory.
- `Project#github_repo_url` constructs a string from `github_repo_full_name` — in-memory.
- CSS additions are tiny (~30 lines); zero asset-pipeline impact.

## Migration Notes

None. No DB changes, no data backfills, no asset reprocessing beyond Tailwind's normal pickup of the modified `application.css`.

## References

- Research: `thoughts/shared/research/2026-05-11/projects-list-row-height-and-info.md`
- Current view: `app/views/projects/index.html.erb:1-43`
- Current CSS block: `app/assets/tailwind/application.css:467-534`
- Controller: `app/controllers/projects_controller.rb:5-7`
- Model helpers: `app/models/project.rb:31-65` (`github_repo_url`, `preview_url`, `preview_running?`)
- Hifumi design system canon: `docs/02-architecture/04-design-system.md` and `CLAUDE.md` (single-file CSS rule)
- Related Hifumi context: `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md`, `thoughts/shared/research/2026-05-09/studio-tabs-and-chat-bubble-contrast.md`
