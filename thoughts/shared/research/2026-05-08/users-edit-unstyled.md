---
date: 2026-05-08T00:00:00+02:00
researcher: Paweł Strzałkowski
git_commit: 8e2743c85c829d22fba2a35ddd740a88962ee97c
branch: main
repository: rails-app-generator
topic: "Why /users/edit is unstyled while /users/sign_up is styled"
tags: [research, devise, hifumi, views, registrations]
status: complete
last_updated: 2026-05-08
last_updated_by: Paweł Strzałkowski
---

# Research: Why /users/edit is unstyled while /users/sign_up is styled

**Date**: 2026-05-08
**Researcher**: Paweł Strzałkowski
**Git Commit**: 8e2743c85c829d22fba2a35ddd740a88962ee97c
**Branch**: main
**Repository**: rails-app-generator

## Research Question
`http://localhost:3000/users/edit` is unstyled even though creating a new account is. Gather knowledge on that.

## Summary
The two pages are rendered by different ERB templates. `app/views/devise/registrations/new.html.erb` was rewritten in commit `6c9234d` (2026-05-01, "design: apply Hifumi design system across visible chrome") to use Hifumi tokens and component classes (`field-label`, `field-input`, `btn btn--accent`, `eyebrow`, `h-section`, `section-rule`, CSS custom properties). The sibling template `app/views/devise/registrations/edit.html.erb` was **not** included in that commit and still emits the original Devise scaffold markup (raw `<h2>`, `<div class="field">`, `<p>` wrappers, default unstyled submit). It is therefore rendered against `app/assets/tailwind/application.css` without referencing any of the Hifumi component classes defined there, so it picks up only the page-level chrome (background, font stack via `<body>`/layout) and none of the form styling.

Three other Devise templates are in the same state — `passwords/new`, `passwords/edit`, `confirmations/new`, `unlocks/new`, plus the shared `_links.html.erb` and `_error_messages.html.erb` partials (the partials were updated for `new`/`edit-account`). Only `registrations/new` and `sessions/new` were styled.

The "Account" link in the global header (`app/views/layouts/application.html.erb:34`) points at `edit_user_registration_path`, so this template is reached from the signed-in nav.

## Detailed Findings

### Routes and controller wiring
- `config/routes.rb:1-6` mounts Devise with a custom registrations controller:
  ```
  devise_for :users, controllers: { registrations: "users/registrations", omniauth_callbacks: "users/omniauth_callbacks" }
  ```
- `/users/edit` resolves to Devise's `RegistrationsController#edit` (subclassed in `app/controllers/users/registrations_controller.rb`), which renders `app/views/devise/registrations/edit.html.erb`.
- `/users/sign_up` resolves to `RegistrationsController#new`, which renders `app/views/devise/registrations/new.html.erb`.

### Styled template — `app/views/devise/registrations/new.html.erb`
File-level audit shows Hifumi tokens throughout (lines cited):
- `<section style="max-width: 480px; margin: 0 auto;">` outer wrapper (line 1)
- `<div class="eyebrow">auth · sign up</div>` (line 2)
- `<h2 class="h-section">` (line 3)
- `form_for(... html: { class: "flex flex-col", style: "gap: 16px;" })` (line 5)
- `f.label :email, class: "field-label"` and `f.email_field ..., class: "field-input"` (lines 9-10), repeated for password / password_confirmation / first_name / last_name / openrouter_api_key (lines 14-48)
- `f.submit "Sign up", class: "btn btn--accent"` (line 51)
- `<hr class="section-rule">` (line 54)
- Inline styles use CSS custom properties (`var(--accent)`, `var(--fg-muted)`, `var(--hi-font-mono)`)

### Unstyled template — `app/views/devise/registrations/edit.html.erb`
File-level audit shows zero Hifumi token usage:
- `<h2>Edit <%= resource_name.to_s.humanize %></h2>` — bare heading (line 1)
- `form_for(... html: { method: :put })` — no class/style on the form (line 3)
- Field markup is the original Devise scaffold pattern: `<div class="field"><p><%= f.label :email %></p><p><%= f.email_field :email %></p></div>` (lines 6-9), repeated for profile fields (lines 11-28), password block (lines 32-43), and current_password (lines 45-50).
- `<%= f.submit "Update" %>` — no class (line 53)
- `<%= button_to "Cancel my account", ... %>` — no class (line 72)
- The GitHub connection block (lines 57-68, added by commit `8e2743c`) is also raw markup: `<h3>`, `<p>`, `button_to` without classes.
- `grep -c "field-input\|btn btn--\|eyebrow\|h-section\|field-label"` returns `0` for this file.

### Hifumi tokens are loaded — they're just not referenced
`app/assets/tailwind/application.css` defines all the relevant component classes:
- `.h-section` (line 131)
- `.eyebrow` (line 153)
- `.field-label` (line 334)
- `.field-input` (line 343, with placeholder + focus rules at 358 / 360)
- `.section-rule` (line 681)
- `.btn`, `.btn--accent` (defined elsewhere in the same file; referenced by `new.html.erb:51`)

The stylesheet is loaded via `app/views/layouts/application.html.erb` for every page. The base layout chrome (paper background, IBM Plex font, header with the "Account" link at line 34) does apply on `/users/edit` — what's missing is the form-component styling, because the template doesn't opt in.

### Audit of all Devise templates

```
app/views/devise/sessions/new.html.erb            STYLED  (7 Hifumi-class hits)
app/views/devise/registrations/new.html.erb      STYLED  (multiple Hifumi-class hits)
app/views/devise/registrations/edit.html.erb     UNSTYLED (0)
app/views/devise/passwords/new.html.erb          UNSTYLED (0)
app/views/devise/passwords/edit.html.erb         UNSTYLED (0)
app/views/devise/confirmations/new.html.erb      UNSTYLED (0)
app/views/devise/unlocks/new.html.erb            UNSTYLED (0)
app/views/devise/shared/_links.html.erb          UNSTYLED (0)
app/views/devise/shared/_error_messages.html.erb UNSTYLED (0)  *
```
*The shared `_error_messages` partial was edited in commit `6c9234d` (the Hifumi commit), so it has Hifumi-aware inline styling/structure even though it doesn't use the audited class names.

### Git history — when each template was last touched
`app/views/devise/registrations/new.html.erb` (styled):
1. `1106fad` — phase 4 step 1: Devise + User + Profile multi-tenancy foundation (initial Devise scaffold)
2. `6c9234d` — design: apply Hifumi design system across visible chrome (rewrote with tokens)

`app/views/devise/registrations/edit.html.erb` (unstyled):
1. `1106fad` — phase 4 step 1 (initial Devise scaffold; same starting point as `new.html.erb`)
2. `69734e9` — phase 4 step 1 fix: only require current_password when changing email or password
3. `8e2743c` — github-export: ship prototype (added the GitHub connection block at lines 57-68)

Commit `6c9234d` ("design: apply Hifumi design system across visible chrome", 2026-05-01) lists the files it migrated:

```
app/views/devise/registrations/new.html.erb       |  86 +--
app/views/devise/sessions/new.html.erb            |  45 +-
app/views/devise/shared/_error_messages.html.erb  |  28 +-
app/views/home/index.html.erb                     |  69 +-
app/views/layouts/application.html.erb            |  49 +-
app/views/messages/_form.html.erb                 |   6 +-
app/views/messages/_message.html.erb              |   8 +-
app/views/previews/_failed.html.erb               |  14 +-
app/views/previews/_pane.html.erb                 |   2 +-
app/views/previews/_running.html.erb              |  23 +-
app/views/previews/_starting.html.erb             |  12 +-
app/views/previews/_stopped.html.erb              |  14 +-
app/views/projects/index.html.erb                 |  50 +-
app/views/projects/new.html.erb                   |  51 +-
app/views/projects/show.html.erb                  |  20 +-
app/views/revisions/_list.html.erb                |   7 +-
app/views/revisions/_revision.html.erb            |  40 +-
app/views/shared/_chat_notice.html.erb            |   9 +-
app/views/suggestions/_frame.html.erb             |   4 +-
```

`registrations/edit.html.erb` and the password/confirmation/unlock templates are absent from that diff.

The commit message on `6c9234d` explicitly lists devise/auth as in scope (`"...landing, projects index/new, studio, revisions, chat, previews, devise auth — now use the Hifumi tokens..."`), but in practice only the two highest-traffic devise screens (sign-up + sign-in) were migrated.

### How users reach `/users/edit`
- Header link in `app/views/layouts/application.html.erb:34`: `<%= link_to "Account", edit_user_registration_path %>`
- Devise's built-in `_links.html.erb` partial does not link to it (it links sign-in / sign-up / forgot-password).
- After a successful registration update, `Users::RegistrationsController` redirects back to `edit_user_registration_path` (Devise default).

### Conventions context — CLAUDE.md
The project's CLAUDE.md (under "Conventions") states:

> **Design system: Hifumi.** All visible chrome (colors, type, components, status tags, marketing pipeline) follows the Hifumi design system applied 2026-05-01. Tokens + component classes live in a single file: `app/assets/tailwind/application.css`. Use the tokens (`--accent`, `--paper-100`, `--ink-800`, `--hi-font-mono`, etc.) — never hardcode hex values. Status indicators are rectangular outlined boxes in mono caps with a stripe + blinking dot for live states, no emoji. Sentence case in every UI string. See `docs/02-architecture/04-design-system.md` for the full token map, component-to-view inventory, and anti-patterns.

So the canonical position is that all visible chrome uses Hifumi tokens; the unstyled Devise templates predate that convention and were not retrofitted in commit `6c9234d`.

## Code References
- `app/views/devise/registrations/edit.html.erb:1-74` — the unstyled template
- `app/views/devise/registrations/new.html.erb:1-59` — the styled sibling, for comparison
- `app/views/devise/registrations/edit.html.erb:57-68` — GitHub connection block added by `8e2743c`, also unstyled
- `app/views/layouts/application.html.erb:34` — `link_to "Account", edit_user_registration_path` (entry point)
- `config/routes.rb:1-5` — Devise mount with custom controllers
- `app/assets/tailwind/application.css:131,153,334,343,358,360,681` — Hifumi component classes that `new.html.erb` uses and `edit.html.erb` does not
- Commit `6c9234d` (2026-05-01) — Hifumi rollout; touched 23 files but not `registrations/edit.html.erb`
- Commit `8e2743c` (2026-05-08, HEAD) — added GitHub connect/disconnect block to `registrations/edit.html.erb` using the same scaffold style as the surrounding (already-unstyled) template

## Architecture Documentation
- Hifumi component classes (`field-label`, `field-input`, `btn`, `btn--accent`, `eyebrow`, `h-section`, `section-rule`) are defined once in `app/assets/tailwind/application.css` and applied per-template by referencing them on form elements.
- Inline `style="..."` is permitted in templates as long as values come from CSS custom properties (`var(--accent)`, `var(--fg-muted)`, `var(--hi-font-mono)`); see `registrations/new.html.erb` lines 17, 42, 45 for the established pattern.
- The base layout (`application.html.erb`) and stylesheet load on every Devise route, including `/users/edit` — page chrome (background, fonts, header) is therefore identical between the two screens; the visible difference is entirely in the form-body markup.
- `app/views/devise/shared/_error_messages.html.erb` was Hifumi-ified in `6c9234d` and is rendered inside both `new` and `edit` (line 6 of `new.html.erb`, line 4 of `edit.html.erb`), so the error block alone would render consistently — but error UI only appears on validation failure.

## Historical Context (from thoughts/)
- `docs/02-architecture/04-design-system.md` is referenced from CLAUDE.md as the full token map and component-to-view inventory; it is the canonical source for which views are expected to use which classes.
- Commit `6c9234d` (2026-05-01) is the Hifumi rollout itself; its commit message ("...devise auth — now use the Hifumi tokens...") describes intent that was only partially realized for the Devise tree.

## Related Research
- `thoughts/shared/research/2026-05-07/` and earlier dated folders contain prior research; none specifically cover the Devise account-edit view.

## Open Questions
- None raised by the user. (Documenting current state only, per the research-mode brief.)
