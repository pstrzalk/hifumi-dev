---
date: 2026-05-11T23:45:24+0000
researcher: Paweł Strzałkowski
git_commit: e3c40401ad0aa23573932aa2fd9fe7f08997c242
branch: main
repository: rails-app-generator
topic: "Devise auth views — 'Sign in with Github' button + cross-screen Log in / Sign up / Forgot password links"
tags: [research, codebase, devise, omniauth, github, auth-ui, hifumi-design-system]
status: complete
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Research: Devise auth views — "Sign in with Github" button + cross-screen Log in / Sign up / Forgot password links

**Date**: 2026-05-11T23:45:24+0000
**Researcher**: Paweł Strzałkowski
**Git Commit**: e3c40401ad0aa23573932aa2fd9fe7f08997c242
**Branch**: main
**Repository**: rails-app-generator

## Research Question

On `http://localhost:3000/users/sign_up` there is a "Sign in with Github" button. GitHub is used for publishing projects, not for registration — document where that button comes from. Also document the placement and styling of the typical Devise cross-screen links (Log in on sign-up page, Sign up on log-in page, Forgot password on log-in page).

## Summary

Every visible authentication screen in the app renders **one shared partial** — `app/views/devise/shared/_links.html.erb` — directly below an `<hr class="section-rule">`. That partial emits:

1. Three text anchors (`link_to`, unclassed — they inherit the global `<a>` style) wrapped in a parent `flex flex-col` with `gap: 6px` and `font-size: 20px`. Each anchor has a `controller_name` guard that hides the link to the page you are currently on:
   - **Log in** — shown on every screen *except* `sessions/new`.
   - **Sign up** — shown on every screen *except* `registrations/new` (requires `registerable`).
   - **Forgot your password?** — shown on every screen *except* `passwords/*` and `registrations/*` (requires `recoverable`).
2. A `button_to "Sign in with Github"` rendered with `class: "btn btn--outline btn--sm"`. This is emitted inside an unguarded `<% if devise_mapping.omniauthable? %>` block that iterates `User.omniauth_providers`, currently `[:github]`. The button is therefore rendered on **all five** Devise screens that render the partial (sign_up, sign_in, passwords/new, passwords/edit, plus the unreachable confirmations/unlocks stubs).

The GitHub button is **the same OAuth target** that the "Connect GitHub" button on `/users/edit` uses (route `user_github_omniauth_authorize`, `POST /users/auth/github`). However, the callback controller (`app/controllers/users/omniauth_callbacks_controller.rb:2`) has `before_action :authenticate_user!`, so the callback only succeeds for an already-logged-in user — it always upserts a `GithubConnection` row owned by `current_user`. There is no anonymous "sign in with GitHub" flow in the codebase; the partial's "Sign in with Github" copy is the literal default string Devise emits for any omniauthable provider, not a real sign-in path.

The header navigation (`app/views/layouts/application.html.erb`) has its own pair of CTAs when signed out: plain "Log in" text link + accent-orange "Sign up" pill. These duplicate two of the body-partial links — so on `/users/sign_in` "Sign up" appears in both the top nav and the body, and on `/users/sign_up` "Log in" appears in both places.

A 2026-05-08 plan explicitly noted that the "Sign in with Github" button is functionally non-functional for sign-in and called fixing/hiding it "out of scope" for that pass (`thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md` lines 43, 54–55).

## Detailed Findings

### 1. Source of the "Sign in with Github" button

**Location**: `app/views/devise/shared/_links.html.erb:21-28`

```erb
<%- if devise_mapping.omniauthable? %>
  <%- resource_class.omniauth_providers.each do |provider| %>
    <%= button_to "Sign in with #{OmniAuth::Utils.camelize(provider)}", omniauth_authorize_path(resource_name, provider),
          data: { turbo: false },
          class: "btn btn--outline btn--sm",
          form: { style: "align-self: flex-start; margin-top: 6px;" } %>
  <% end %>
<% end %>
```

**Why it renders**:
- `app/models/user.rb:2-4` declares the User as `:omniauthable, omniauth_providers: %i[github]`.
- `devise_mapping.omniauthable?` is therefore true, and `User.omniauth_providers` is `[:github]`.
- The branch has **no** `controller_name` guard (unlike Log in / Sign up / Forgot), so the button is rendered on every screen that renders the partial.
- The string is `"Sign in with #{OmniAuth::Utils.camelize(provider)}"` — literal default Devise copy with the provider name capitalised. There is no override.

**Target route**:
- `omniauth_authorize_path(:user, :github)` → `user_github_omniauth_authorize` → `POST /users/auth/github` (devise-routed to `users/omniauth_callbacks#passthru`, which redirects to GitHub).
- Listed in `bin/rails routes`:
  ```
  user_github_omniauth_authorize  POST  /users/auth/github            users/omniauth_callbacks#passthru
  user_github_omniauth_callback   GET|POST  /users/auth/github/callback  users/omniauth_callbacks#github
  ```

**Devise + OmniAuth wiring**:
- `config/initializers/devise.rb:279-282` registers the GitHub provider with `repo` scope:
  ```ruby
  config.omniauth :github,
    ENV.fetch("GITHUB_CLIENT_ID", nil),
    ENV.fetch("GITHUB_CLIENT_SECRET", nil),
    scope: "repo"
  ```
- `config/routes.rb:2-6` mounts the custom controllers: `omniauth_callbacks: "users/omniauth_callbacks"`.

**Callback behaviour** (`app/controllers/users/omniauth_callbacks_controller.rb`):

```ruby
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  before_action :authenticate_user!

  def github
    auth = request.env["omniauth.auth"]
    connection = current_user.github_connection || current_user.build_github_connection
    connection.update!(provider: "github_oauth", github_username: auth.info.nickname,
                       github_user_id: auth.uid.to_i, access_token: auth.credentials.token)
    redirect_to edit_user_registration_path, notice: "Connected as @#{connection.github_username}."
  end

  def failure
    redirect_to edit_user_registration_path, alert: "GitHub connection failed: #{failure_message}"
  end
end
```

- The `before_action :authenticate_user!` on **line 2** means: an anonymous visitor who clicks the button on `/users/sign_up`, completes the GitHub OAuth round-trip, and hits `/users/auth/github/callback` will be intercepted by Devise's `authenticate_user!` and redirected to `/users/sign_in`. No user row is created, no `GithubConnection` row is created, and no error message specifically explains this.
- The handler's only side-effect is building/updating `current_user.github_connection` — i.e. it is exclusively a "connect my already-existing account to GitHub for publishing" path.

**The matching "Connect GitHub" button on the account edit page** uses the same authorize endpoint:

`app/views/devise/registrations/edit.html.erb:84-85`:
```erb
<%= button_to "Connect GitHub", user_github_omniauth_authorize_path, method: :post,
      data: { turbo: false }, class: "btn btn--outline" %>
```

Same route, different button copy, different styling (no `btn--sm`), and only rendered when `current_user.github_connection&.connected?` is false.

### 2. Devise screens that render `_links`

Every Devise view ends with the same trailer block (separator + flex column wrapping the partial):

```erb
<hr class="section-rule" style="margin: 24px 0;">

<div class="flex flex-col" style="gap: 6px; font-size: 20px;">
  <%= render "devise/shared/links" %>
</div>
```

Verified in:
- `app/views/devise/registrations/new.html.erb:54-58` (sign-up)
- `app/views/devise/sessions/new.html.erb:26-30` (log-in)
- `app/views/devise/passwords/new.html.erb:16-20` (forgot password)
- `app/views/devise/passwords/edit.html.erb:27-31` (reset password)

Two view files exist but are **unreachable** (User is not `:confirmable` or `:lockable`, so no routes exist for them):
- `app/views/devise/confirmations/new.html.erb:16` — renders `_links`, but `bin/rails routes` has no entry.
- `app/views/devise/unlocks/new.html.erb:16` — same.

`app/views/devise/registrations/edit.html.erb` does **not** render `_links`; the account-edit page has its own GitHub connection `<section>` (lines 69-90) and a danger-zone Cancel-my-account section (lines 92-102).

### 3. `_links.html.erb` — full body and conditional logic

`app/views/devise/shared/_links.html.erb`:

```erb
<%- if controller_name != 'sessions' %>
  <%= link_to "Log in", new_session_path(resource_name) %>
<% end %>

<%- if devise_mapping.registerable? && controller_name != 'registrations' %>
  <%= link_to "Sign up", new_registration_path(resource_name) %>
<% end %>

<%- if devise_mapping.recoverable? && controller_name != 'passwords' && controller_name != 'registrations' %>
  <%= link_to "Forgot your password?", new_password_path(resource_name) %>
<% end %>

<%- if devise_mapping.confirmable? && controller_name != 'confirmations' %>
  <%= link_to "Didn't receive confirmation instructions?", new_confirmation_path(resource_name) %>
<% end %>

<%- if devise_mapping.lockable? && resource_class.unlock_strategy_enabled?(:email) && controller_name != 'unlocks' %>
  <%= link_to "Didn't receive unlock instructions?", new_unlock_path(resource_name) %>
<% end %>

<%- if devise_mapping.omniauthable? %>
  <%- resource_class.omniauth_providers.each do |provider| %>
    <%= button_to "Sign in with #{OmniAuth::Utils.camelize(provider)}", omniauth_authorize_path(resource_name, provider),
          data: { turbo: false },
          class: "btn btn--outline btn--sm",
          form: { style: "align-self: flex-start; margin-top: 6px;" } %>
  <% end %>
<% end %>
```

**Resulting per-page contents** (given the User's enabled modules: `database_authenticatable, registerable, recoverable, rememberable, validatable, omniauthable`):

| Page (controller_name) | Log in | Sign up | Forgot password? | Confirm | Unlock | Sign in with Github |
|---|---|---|---|---|---|---|
| `/users/sign_up` (registrations) | ✓ | — (hidden, current page) | **—** (guard explicitly excludes `registrations`) | inert | inert | ✓ |
| `/users/sign_in` (sessions) | — (current) | ✓ | ✓ | inert | inert | ✓ |
| `/users/password/new` (passwords) | ✓ | ✓ | — (current) | inert | inert | ✓ |
| `/users/password/edit` (passwords) | ✓ | ✓ | — (passwords) | inert | inert | ✓ |
| `/users/edit` (registrations) | (partial not rendered) | | | | | |

> "inert" = the `confirmable?` / `lockable?` branch is structurally present but the predicates are false because those Devise modules are not enabled on `User`.

**Notable**: the "Forgot your password?" guard on line 9 is `controller_name != 'passwords' && controller_name != 'registrations'`. The exclusion of `'registrations'` means the sign-up page does NOT show a "Forgot your password?" link. The sign-in page does.

### 4. Styling — the Hifumi component classes that show up here

Source: `app/assets/tailwind/application.css`.

- `.field-input` / `.field-label` (lines 401, 410): field rows used on every Devise form.
- `.btn` family: `.btn--accent` (orange CTA, line 384), `.btn--primary` (dark ink), `.btn--outline` (line 387 — transparent with a strong border), `.btn--danger` (line 393), `.btn--sm` (line 396, font 20px / padding 6×10).
- `.eyebrow` (line 155): small mono caps label above the heading — every Devise screen has one (`auth · sign up`, `auth · log in`, `auth · forgot password`, `auth · reset password`, `account · profile`, `account · github`, `account · danger zone`).
- `.h-section` (line 133): main page heading.
- `.section-rule` (line 855): the `<hr>` separator before the links block.

The link anchors themselves are **unclassed** — they inherit the global `a { ... }` style defined in `application.css` (per the 2026-05-08 plan: *"Anchor tags inherit Hifumi link styling via the global `a { … }` rule in `application.css` — no per-link class needed."*).

The omniauth button is the only element in the links block with explicit button styling: `btn btn--outline btn--sm`, with the surrounding `<form>` carrying inline `align-self: flex-start; margin-top: 6px;` so the form doesn't stretch to full width and so the button drops 6px below the previous link.

### 5. Header chrome around these pages

`app/views/layouts/application.html.erb:27-45`:

- Body wraps everything in `<body class="app-shell">` with a top `<nav class="app-nav">`.
- **Signed out** (the state every visitor of `/users/sign_up`, `/users/sign_in`, `/users/password/*` is in):
  ```erb
  <%= link_to root_path, class: "app-nav-brand" do %>
    <span class="kanji" aria-hidden="true">一二三</span>hifumi<span class="tld">.dev</span>
  <% end %>
  <%= link_to "Log in", new_user_session_path %>
  <span class="app-nav-sep">·</span>
  <%= link_to "Sign up", new_user_registration_path, class: "btn btn--accent btn--sm" %>
  ```
  → on every signed-out page the top nav has: brand · "Log in" (plain) · "Sign up" (orange pill).
- Notice and alert flashes are rendered as `.notice-strip` blocks at the top of `<main>`.

This produces visual duplication on Devise screens:
- `/users/sign_up`: top-nav "Log in" + body-partial "Log in" link (both go to `/users/sign_in`).
- `/users/sign_in`: top-nav "Sign up" (orange pill) + body-partial "Sign up" link.
- `/users/password/new`: top-nav "Log in" + "Sign up", plus body-partial "Log in" + "Sign up".

### 6. The sign-up form itself (for context)

`app/views/devise/registrations/new.html.erb` renders (in order):
1. `.eyebrow` "auth · sign up" + `h2.h-section` "Sign up".
2. `form_for(resource, ...)` containing: email, password (with `@minimum_password_length` helper text), password_confirmation, then nested `f.fields_for :profile` with `first_name`, `last_name`, and `openrouter_api_key` (with a helper paragraph linking to `openrouter.ai/keys`).
3. `f.submit "Sign up"` with `class: "btn btn--accent"`.
4. `<hr class="section-rule">`.
5. `<%= render "devise/shared/links" %>` — emits in order: "Log in" link, then the "Sign in with Github" button (no Forgot-your-password link here, per the guard).

The custom `Users::RegistrationsController#new` (`app/controllers/users/registrations_controller.rb:5-9`) calls `resource.build_profile` so the nested `fields_for :profile` block has an instance to bind to.

### 7. GitHub connection model and post-callback flow

After a logged-in user finishes the GitHub OAuth round-trip, the callback writes a single row owned by them:

- `app/models/github_connection.rb`: `belongs_to :user, inverse_of: :github_connection`. Stores `provider`, `github_username`, `github_user_id`, `encrypts :access_token`, `encrypts :refresh_token`. `#connected? = access_token.present?`.
- `app/models/user.rb:12`: `has_one :github_connection, dependent: :destroy, inverse_of: :user`.
- `db/migrate/20260507180925_create_github_connections.rb` is the migration.
- Disconnect path: `app/controllers/github_connections_controller.rb` — `DELETE /github_connection` destroys the row and redirects to `edit_user_registration_path`.

The end-to-end happy and failure paths are exercised by `test/integration/github_oauth_test.rb` (signs the user in *first*, then visits the callback). No test exists for "anonymous click on Sign in with Github" because there is no controller path for it.

## Code References

- `app/views/devise/shared/_links.html.erb:1-28` — the single source of every "Log in / Sign up / Forgot / Sign in with Github" link on Devise screens.
- `app/views/devise/registrations/new.html.erb:54-58` — sign-up page renders the partial below `section-rule`.
- `app/views/devise/sessions/new.html.erb:26-30` — log-in page renders the partial below `section-rule`.
- `app/views/devise/passwords/new.html.erb:16-20` — forgot-password page renders the partial.
- `app/views/devise/passwords/edit.html.erb:27-31` — reset-password page renders the partial.
- `app/views/devise/registrations/edit.html.erb:69-90` — `/users/edit` has its own GitHub section (does not render `_links`).
- `app/views/layouts/application.html.erb:38-43` — signed-out top-nav "Log in" + "Sign up" pill.
- `app/models/user.rb:2-4` — `:omniauthable, omniauth_providers: %i[github]`.
- `app/controllers/users/omniauth_callbacks_controller.rb:1-22` — `before_action :authenticate_user!` makes the callback owner-only.
- `app/controllers/users/registrations_controller.rb:5-9` — `new` builds the nested `Profile` for the form.
- `config/initializers/devise.rb:279-282` — `config.omniauth :github, ...` with `scope: "repo"`.
- `config/routes.rb:2-6` — Devise routes mount with custom `registrations` and `omniauth_callbacks` controllers.
- `app/assets/tailwind/application.css:131-160` (`.h-section`, `.eyebrow`), `:384-396` (`.btn--*` variants), `:401-431` (`.field-label`, `.field-input`), `:855-858` (`.section-rule`).

## Architecture Documentation

- **Hifumi design system** (`docs/02-architecture/04-design-system.md`): the design tokens, component classes, and font tri-system (Plex Sans / Plex Mono / Source Serif 4) used by every Devise screen.
- **Two-tone CTA convention** (per the 2026-05-08 plan): sign-up uses `btn--accent` (orange) — the "primary growth" CTA; log-in and other secondary auth uses `btn--primary` (dark ink). The top-nav reflects the same: "Sign up" gets the orange pill, "Log in" stays as a plain text link.
- **GitHub-for-publishing vs. GitHub-for-sign-in**: only the publishing path exists. The omniauth provider is registered solely for the `repo`-scoped publish flow (`config/initializers/devise.rb:282`). The callback guards itself with `authenticate_user!` so the wiring presupposes an authenticated session. The "Sign in with Github" button in `_links` is the default Devise emission for any omniauthable provider, not a designed feature.
- **Shared trailer pattern**: every Devise form view is structured identically — `section` → `eyebrow` → `h-section` → `form_for` → `<hr class="section-rule">` → `flex flex-col` rendering `_links`. This means any change to the partial cascades to all four (reachable) auth screens uniformly.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md`
  - **Lines 43, 54–55**: explicitly identified the "Sign in with Github" button as broken for sign-in (callback requires `authenticate_user!`) and put fixing/hiding it out of scope:
    > *"`_links.html.erb` emits a `button_to "Sign in with Github"` on every auth screen that renders the partial — including `registrations/new` (the omniauth branch in `_links.html.erb` has no `controller_name` guard). The omniauth callback ... requires `authenticate_user!`, so this button is currently effectively non-functional for sign-in. **In scope for styling only — fixing or hiding it is out of scope.**"*
    > *"**Not fixing the omniauth-on-sign-in bug.** The 'Sign in with Github' button shows on auth screens and routes to a callback that requires authentication — broken UX, but a separate decision (hide it from `_links` or add proper sign-in-with-github support). This plan styles whatever the partial currently emits."*
  - **Lines 75-119**: documents the Phase 1 rewrite of `_links.html.erb` that produced the current code — dropped the `<p>` wrappers, kept the link conditionals 1:1, added `btn btn--outline btn--sm` styling to the omniauth button and the `form: { style: ... }` trick to make `button_to` align with the flex column.
- `thoughts/shared/plans/2026-04-28/phase-4a-auth-and-ownership.md`
  - Phase 4a established Devise + Profile + per-user OpenRouter key. The user-journey premise (line 55) makes clear that GitHub OAuth was introduced *after* sign-up for the publishing-to-GitHub flow, not as a sign-in mechanism: *"per-user OpenRouter key (BYOK)"* sign-up, no mention of GitHub at sign-up.
- `thoughts/shared/research/2026-05-08/users-edit-unstyled.md` — the research that fed the styling plan above (companion document).
- `thoughts/shared/research/2026-05-07/github-export-integration.md` — research that fed the GitHub publishing prototype shipped in commit `8e2743c`.

## Related Research

- `thoughts/shared/research/2026-05-09/typography-font-size-inventory.md`
- `thoughts/shared/research/2026-05-08/users-edit-unstyled.md`
- `thoughts/shared/research/2026-05-08/authenticated-screens-layout-and-project-show-tabs.md`
- `thoughts/shared/research/2026-05-07/github-export-integration.md`

## Open Questions

None — the user's question was a documentation request and the present state is fully described above. The user has signalled an intent to remove the omniauth button from the auth screens and rework the placement of the cross-screen links; those would be addressed by a separate plan, not by further research.
