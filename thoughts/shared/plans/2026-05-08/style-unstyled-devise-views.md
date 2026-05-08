---
date: 2026-05-08
author: Paweł Strzałkowski
status: draft
related_research: thoughts/shared/research/2026-05-08/users-edit-unstyled.md
related_commit: 6c9234d (Hifumi rollout, 2026-05-01)
---

# Style remaining unstyled Devise views — Implementation Plan

## Overview

Apply the Hifumi design system to the Devise screens that the 2026-05-01 rollout (`6c9234d`) skipped. Bring `registrations/edit`, `passwords/new`, `passwords/edit`, and the shared `_links` partial up to the visual idiom established by `registrations/new.html.erb` and `sessions/new.html.erb`.

## Current State Analysis

The 2026-05-01 Hifumi rollout migrated `sessions/new` and `registrations/new` to Hifumi tokens but left the rest of the Devise tree on the original Rails/Devise scaffold markup (`<div class="field"><p>label</p><p>input</p></div>`, unclassed `<h2>` / `<h3>`, default unstyled submit buttons). The base layout, fonts, paper background, and `_error_messages` partial *do* render correctly on those pages — the gap is entirely at form-component level.

Four files are currently in the unstyled state. (`app/views/devise/confirmations/new.html.erb` and `app/views/devise/unlocks/new.html.erb` also exist on disk but are unreachable — `User.devise_modules` is `[:database_authenticatable, :rememberable, :omniauthable, :recoverable, :registerable, :validatable]`, so neither `:confirmable` nor `:lockable` is enabled and `bin/rails routes | grep -iE 'confirmation|unlock'` returns nothing. They are scaffold leftovers from `bin/rails g devise:views`. Out of scope — see "What We're NOT Doing".)

| File | Used by | Notes |
|---|---|---|
| `app/views/devise/registrations/edit.html.erb` | `/users/edit` (header "Account" link) | 3 logical groups: profile/email/password form, GitHub connection, Cancel my account |
| `app/views/devise/passwords/new.html.erb` | `/users/password/new` ("Forgot your password?") | Single email field |
| `app/views/devise/passwords/edit.html.erb` | `/users/password/edit?token=…` (link from reset email) | New password + confirmation, hidden reset_password_token |
| `app/views/devise/shared/_links.html.erb` | rendered by every styled and unstyled auth screen | Currently emits `<p><%= link_to … %></p>`; the `<p>` margins fight the parent `flex flex-col gap:6px` container on the styled screens |

The full reference pattern from `registrations/new.html.erb` is:
- Outer `<section style="max-width: 480px; margin: 0 auto;">` (or 420px for shorter forms)
- `<div class="eyebrow">auth · …</div>` + `<h2 class="h-section" style="margin: 4px 0 24px;">Title</h2>`
- `form_for(... html: { class: "flex flex-col", style: "gap: 16px;" })`
- Each field: `<div>` containing `f.label …, class: "field-label"` and `f.<type>_field …, class: "field-input"`; helper copy as `<p style="margin: 6px 0 0; font-size: 12px; color: var(--fg-muted);">…</p>` directly below the input
- Submit: `f.submit "…", class: "btn btn--accent", style: "align-self: flex-start;"`
- `<hr class="section-rule" style="margin: 24px 0;">` ahead of links
- `<div class="flex flex-col" style="gap: 6px; font-size: 13px;"><%= render "devise/shared/links" %></div>`

The shared `_error_messages` partial (already Hifumi-styled in `6c9234d`) is rendered by every form and needs no changes.

### Key Discoveries
- `app/assets/tailwind/application.css` defines all needed components: `.eyebrow` (line 153), `.h-section` (131), `.field-label` (334), `.field-input` (343), `.btn` / `.btn--accent` / `.btn--primary` / `.btn--danger` (289–327), `.section-rule` (681), `.notice-strip*` (232–284). Tokens already in scope on every Devise route.
- `sessions/new.html.erb:23` uses `btn btn--primary` (dark ink) for log-in; `registrations/new.html.erb:51` uses `btn btn--accent` (orange) for sign-up. The two primary auth CTAs intentionally use different button variants — sign-up is the primary call-to-action.
- `_links.html.erb` is a Devise-level partial; changing it affects the already-styled `sessions/new` and `registrations/new` (improves them — replaces `<p>` margins with flex `gap`).
- `User` is `omniauthable` with `github` (`app/models/user.rb:4`), so `_links.html.erb` emits a `button_to "Sign in with Github"` on every auth screen that renders the partial — including `registrations/new` (the omniauth branch in `_links.html.erb` has no `controller_name` guard). The omniauth callback (`app/controllers/users/omniauth_callbacks_controller.rb:2`) requires `authenticate_user!`, so this button is currently effectively non-functional for sign-in. **In scope for styling only — fixing or hiding it is out of scope.**
- `test/integration/github_oauth_test.rb:106,119` calls `get edit_user_registration_path` and would catch a render error; `test/controllers/users/registrations_controller_test.rb` covers the sign-up form GET but not the edit GET.
- CLAUDE.md (Conventions / Design system) mandates Hifumi tokens, sentence case, no emoji, no hardcoded hex.

## Desired End State

Every Devise screen reachable via `bin/rails routes | grep devise` renders with the Hifumi component classes — eyebrow, h-section heading, field-label/field-input form rows, btn-class submits, section-rule separators, and the styled `_links` partial. Visual parity with `registrations/new` and `sessions/new`. `grep -c 'field-label\|field-input\|btn btn--\|eyebrow\|h-section\|section-rule' app/views/devise/**/*.erb` returns non-zero for every file in scope.

How to verify: walk through `/users/sign_up`, `/users/sign_in`, `/users/edit`, `/users/password/new`, `/users/password/edit?reset_password_token=invalid` in the browser. Each screen should look like a sibling of the existing sign-up/log-in pages.

## What We're NOT Doing

- **Not fixing the omniauth-on-sign-in bug.** The "Sign in with Github" button shows on auth screens and routes to a callback that requires authentication — broken UX, but a separate decision (hide it from `_links` or add proper sign-in-with-github support). This plan styles whatever the partial currently emits.
- **Not editing Devise mailer templates** (`app/views/devise/mailer/*.erb`). HTML email is a separate styling concern with its own constraints.
- **Not changing route paths, controllers, or copy semantics.** Visible labels may be tweaked to sentence case where they aren't (e.g. "Send me password reset instructions" stays — already sentence case).
- **Not adding new Hifumi component classes.** Reuse what exists in `application.css`. If a need surfaces, surface it as a follow-up.
- **Not writing system/feature tests** for visual styling. Manual verification is the canonical check (per CLAUDE.md status; W2.4 verify can't run headless Chrome — see `project_verify_no_system_tests.md`). Render-smoke is covered by existing integration tests.
- **Not designing a "danger zone" panel.** Per the chosen layout option, "Cancel my account" is its own `<section>` block — the existing `btn btn--danger` and confirm dialog are sufficient.
- **Not styling `confirmations/new.html.erb` or `unlocks/new.html.erb`.** Those view files exist as `bin/rails g devise:views` scaffold leftovers but are unreachable — `User` has neither `:confirmable` nor `:lockable`, so the corresponding routes don't exist. Leave them untouched; if/when those modules are enabled later, style them then. The `confirmable?` / `lockable?` branches in `_links.html.erb` (Phase 1) are inert in this app and harmless to leave in their bare-link form.

## Implementation Approach

Three phases, each one atomic commit:

1. **Restyle the shared `_links` partial first** — it's a dependency of every other auth screen and the change is small, isolated, and improves the already-styled screens incidentally.
2. **Style the two short-form Devise screens together** (`passwords/new`, `passwords/edit`) — they share an almost-identical shape (single-purpose form, one email or new-password input, single submit). Splitting them into two commits would be churn for no reviewability win.
3. **Style `registrations/edit.html.erb`** — the largest and structurally distinct piece. Three independent `<section>` blocks (profile form, GitHub connection, Cancel my account) per the chosen layout.

Mechanical translation (no controller, no route, no model changes); each phase is reviewable as a pure-template diff.

---

## Phase 1: Restyle the shared `_links` partial

### Commit
`design: hifumi-style devise shared _links partial`

### Overview
Replace `<p>`-wrapped links with flex-friendly bare children. Style the omniauth `button_to` with `btn btn--outline btn--sm`. The change improves spacing on the two already-styled screens (`sessions/new`, `registrations/new`) where the parent container is `flex flex-col gap:6px` — currently `<p>` margins win and the gap is unused.

### Changes Required

#### `app/views/devise/shared/_links.html.erb`
**Changes**: Drop `<p>` wrappers around `link_to` so each anchor is a direct child of the parent flex container; keep the existing conditional structure 1:1; replace the unstyled omniauth `button_to` with one carrying `class: "btn btn--outline btn--sm"`. Anchor tags inherit Hifumi link styling via the global `a { … }` rule in `application.css` — no per-link class needed.

**Note on `button_to` and the parent flex container**: `button_to` wraps the button in a `<form>`. The form is the flex child of the parent `flex flex-col` container — *not* the button. Rails' `class:` and `style:` options go on the inner `<button>`, so layout-level styling (alignment relative to siblings, gap to the previous link) must be passed via the `form:` option. Below, `class: "btn btn--outline btn--sm"` styles the button itself and `form: { style: "align-self: flex-start; margin-top: 6px;" }` shrinks the form to button width and offsets it below the links.

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

### Success Criteria

#### Automated Verification
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] No ERB syntax errors: `bin/rails routes` runs cleanly (the framework eager-loads view paths in dev)
- [x] Existing auth tests still pass: `bin/rails test test/controllers/users/registrations_controller_test.rb test/integration/github_oauth_test.rb`

#### Manual Verification
- [ ] `/users/sign_in` — links list directly below the section-rule shows correct 6px gap (no double-spacing from `<p>` margins). Links: "Sign up", "Forgot your password?". Omniauth button "Sign in with Github" rendered as `btn--outline btn--sm`, left-aligned, slightly offset below the links.
- [ ] `/users/sign_up` — links list shows: "Log in", "Forgot your password?", omniauth button styled identically to sign-in. Spacing is even (no orphan margin).
- [ ] No visual regression on any auth screen header/eyebrow/main form (the change is below the `<hr class="section-rule">`).

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation that the styled screens still render correctly before moving to Phase 2.

---

## Phase 2: Style the two short-form Devise screens

### Commit
`design: hifumi-style devise password screens`

### Overview
Apply the established sign-in/sign-up template idiom to the two short auth screens (request reset, set new password). Both use a 420px-wide section, eyebrow + h-section heading, field-label/field-input rows, `btn btn--primary` submit (matching the secondary-auth tone of `sessions/new`), section-rule separator, and the now-styled `_links` partial.

### Changes Required

#### 1. `app/views/devise/passwords/new.html.erb`

```erb
<section style="max-width: 420px; margin: 0 auto;">
  <div class="eyebrow">auth · forgot password</div>
  <h2 class="h-section" style="margin: 4px 0 24px;">Forgot your password?</h2>

  <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :post, class: "flex flex-col", style: "gap: 16px;" }) do |f| %>
    <%= render "devise/shared/error_messages", resource: resource %>

    <div>
      <%= f.label :email, class: "field-label" %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email", class: "field-input" %>
    </div>

    <%= f.submit "Send me password reset instructions", class: "btn btn--primary", style: "align-self: flex-start;" %>
  <% end %>

  <hr class="section-rule" style="margin: 24px 0;">

  <div class="flex flex-col" style="gap: 6px; font-size: 13px;">
    <%= render "devise/shared/links" %>
  </div>
</section>
```

#### 2. `app/views/devise/passwords/edit.html.erb`

```erb
<section style="max-width: 420px; margin: 0 auto;">
  <div class="eyebrow">auth · reset password</div>
  <h2 class="h-section" style="margin: 4px 0 24px;">Change your password</h2>

  <%= form_for(resource, as: resource_name, url: password_path(resource_name), html: { method: :put, class: "flex flex-col", style: "gap: 16px;" }) do |f| %>
    <%= render "devise/shared/error_messages", resource: resource %>
    <%= f.hidden_field :reset_password_token %>

    <div>
      <%= f.label :password, "New password", class: "field-label" %>
      <%= f.password_field :password, autofocus: true, autocomplete: "new-password", class: "field-input" %>
      <% if @minimum_password_length %>
        <p style="margin: 6px 0 0; font-size: 12px; color: var(--fg-muted);">
          <%= @minimum_password_length %> characters minimum.
        </p>
      <% end %>
    </div>

    <div>
      <%= f.label :password_confirmation, "Confirm new password", class: "field-label" %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password", class: "field-input" %>
    </div>

    <%= f.submit "Change my password", class: "btn btn--primary", style: "align-self: flex-start;" %>
  <% end %>

  <hr class="section-rule" style="margin: 24px 0;">

  <div class="flex flex-col" style="gap: 6px; font-size: 13px;">
    <%= render "devise/shared/links" %>
  </div>
</section>
```

### Success Criteria

#### Automated Verification
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Full test suite green: `bin/rails test`
- [x] Both templates reference the Hifumi tokens: `grep -lE 'field-label|field-input|btn btn--|eyebrow|h-section|section-rule' app/views/devise/passwords/new.html.erb app/views/devise/passwords/edit.html.erb` returns both paths.

#### Manual Verification
- [ ] `/users/password/new` — page resembles `/users/sign_in`: 420px column, eyebrow `auth · forgot password`, h-section heading, single email field with field-input border + focus ring, `btn--primary` submit, section-rule separator, links list below.
- [ ] `/users/password/edit?reset_password_token=invalid` — same idiom; password + confirmation fields rendered. Submitting the form with the invalid token surfaces the styled `_error_messages` notice-strip.
- [ ] On both screens, the `_links` partial renders correctly and the omniauth button (Phase 1) appears as `btn--outline btn--sm`.
- [ ] No emoji or hardcoded hex introduced (per CLAUDE.md).

**Implementation Note**: After completing this phase and all automated verification passes, pause for manual confirmation before moving to Phase 3.

---

## Phase 3: Style `registrations/edit.html.erb`

### Commit
`design: hifumi-style devise account edit page`

### Overview
Replace the scaffold markup on `/users/edit` with three independent `<section>` blocks per the chosen layout: (1) the account form (email + profile fields + optional password change + current_password), (2) GitHub connection, (3) Cancel my account. Each section gets its own eyebrow, h-section heading, and is centered at 480px (matching `registrations/new`). The form uses `btn btn--accent` to match sign-up; GitHub connect/disconnect uses `btn btn--outline` (connect) and `btn btn--danger` (disconnect); Cancel my account uses `btn btn--danger`.

The page already has good content structure; the diff is a markup translation, not a content reorganization.

### Changes Required

#### `app/views/devise/registrations/edit.html.erb`

```erb
<section style="max-width: 480px; margin: 0 auto;">
  <div class="eyebrow">account · profile</div>
  <h2 class="h-section" style="margin: 4px 0 24px;">Edit account</h2>

  <%= form_for(resource, as: resource_name, url: registration_path(resource_name),
        html: { method: :put, class: "flex flex-col", style: "gap: 16px;" }) do |f| %>
    <%= render "devise/shared/error_messages", resource: resource %>

    <div>
      <%= f.label :email, class: "field-label" %>
      <%= f.email_field :email, autofocus: true, autocomplete: "email", class: "field-input" %>
    </div>

    <%= f.fields_for :profile do |pf| %>
      <div>
        <%= pf.label :first_name, class: "field-label" %>
        <%= pf.text_field :first_name, class: "field-input" %>
      </div>

      <div>
        <%= pf.label :last_name, class: "field-label" %>
        <%= pf.text_field :last_name, class: "field-input" %>
      </div>

      <div>
        <%= pf.label :openrouter_api_key, "OpenRouter API key", class: "field-label" %>
        <%= pf.password_field :openrouter_api_key, autocomplete: "off",
              placeholder: "(unchanged — leave blank to keep current key)", class: "field-input" %>
        <p style="margin: 6px 0 0; font-size: 12px; color: var(--fg-muted);">
          Rotate at
          <a href="https://openrouter.ai/keys" target="_blank"
             style="color: var(--accent); text-decoration: underline; text-underline-offset: 2px;">openrouter.ai/keys</a>.
        </p>
      </div>
    <% end %>

    <hr class="section-rule" style="margin: 8px 0;">
    <div class="eyebrow">change password</div>

    <div>
      <%= f.label :password, "New password", class: "field-label" %>
      <%= f.password_field :password, autocomplete: "new-password", class: "field-input" %>
      <% if @minimum_password_length %>
        <p style="margin: 6px 0 0; font-size: 12px; color: var(--fg-muted);">
          <%= @minimum_password_length %> characters minimum.
        </p>
      <% end %>
    </div>

    <div>
      <%= f.label :password_confirmation, class: "field-label" %>
      <%= f.password_field :password_confirmation, autocomplete: "new-password", class: "field-input" %>
    </div>

    <hr class="section-rule" style="margin: 8px 0;">

    <div>
      <%= f.label :current_password, class: "field-label" %>
      <%= f.password_field :current_password, autocomplete: "current-password", class: "field-input" %>
      <p style="margin: 6px 0 0; font-size: 12px; color: var(--fg-muted);">
        Only required when changing your email or password.
      </p>
    </div>

    <%= f.submit "Update account", class: "btn btn--accent", style: "align-self: flex-start;" %>
  <% end %>
</section>

<section style="max-width: 480px; margin: 32px auto 0;">
  <hr class="section-rule" style="margin: 0 0 24px;">
  <div class="eyebrow">account · github</div>
  <h2 class="h-section" style="margin: 4px 0 16px;">GitHub connection</h2>

  <% if current_user.github_connection&.connected? %>
    <p style="margin: 0 0 12px; font-size: 13px; color: var(--fg-muted);">
      Connected as
      <a href="<%= current_user.github_connection.github_url %>" target="_blank"
         style="color: var(--accent); text-decoration: underline; text-underline-offset: 2px;">@<%= current_user.github_connection.github_username %></a>.
    </p>
    <%= button_to "Disconnect GitHub", github_connection_path, method: :delete,
          data: { turbo_confirm: "Disconnect from GitHub? You'll need to reauthorize before exporting again." },
          class: "btn btn--danger" %>
  <% else %>
    <%= button_to "Connect GitHub", user_github_omniauth_authorize_path, method: :post,
          data: { turbo: false }, class: "btn btn--outline" %>
    <p style="margin: 8px 0 0; font-size: 12px; color: var(--fg-muted);">
      Required to export projects to your GitHub account. Grants access to your repositories (<code style="font-family: var(--hi-font-mono);">repo</code> scope).
    </p>
  <% end %>
</section>

<section style="max-width: 480px; margin: 32px auto 0;">
  <hr class="section-rule" style="margin: 0 0 24px;">
  <div class="eyebrow">account · danger zone</div>
  <h2 class="h-section" style="margin: 4px 0 16px;">Cancel my account</h2>

  <p style="margin: 0 0 12px; font-size: 13px; color: var(--fg-muted);">
    Deletes your account and all associated projects. This cannot be undone.
  </p>
  <%= button_to "Cancel my account", registration_path(resource_name), method: :delete,
        data: { turbo_confirm: "Are you sure?" }, class: "btn btn--danger" %>
</section>
```

Notes on the diff:
- Drops the bare `<%= link_to "Back", :back %>` at the bottom — global header (`application.html.erb:34`) and breadcrumbs already provide navigation; the link as written has no class and no clear destination after a save (browser back stack varies). Out-of-scope changes are minimized, but this anchor was a stray scaffold artifact, not a styled element to retain.
- The "Change password" sub-area lives inside the same form section but is visually separated by `<hr class="section-rule" style="margin: 8px 0;">` + a small eyebrow — it's still one form (a single `Update account` submit), just visually grouped. This matches the layout option chosen ("separate sections per group" applies to profile / GitHub / Cancel; the password block is logically part of the profile form because it shares the submit button and `current_password` requirement).
- `data: { confirm: ... }` (legacy Rails UJS) was paired with `turbo_confirm` in the old markup; only `turbo_confirm` is needed in Rails 8 / Turbo. Drop the legacy key.
- `<i>(only required if changing email or password)</i>` becomes muted help-text under the field, matching the established help-text pattern.

### Success Criteria

#### Automated Verification
- [x] App boots: `bin/rails runner 'puts "ok"'`
- [x] Full test suite green: `bin/rails test`
- [x] `test/integration/github_oauth_test.rb` (which `get edit_user_registration_path` twice) passes — render-smoke for both GitHub-connected and disconnected branches.
- [x] Template references Hifumi tokens: `grep -cE 'field-label|field-input|btn btn--|eyebrow|h-section|section-rule' app/views/devise/registrations/edit.html.erb` returns >= 10.
- [x] No `<div class="field">` or scaffold-style `<p><%= f.label`: `grep -E '<div class="field"|<p><%= f\.label' app/views/devise/registrations/edit.html.erb` returns empty.

#### Manual Verification
- [ ] `/users/edit` (signed in, GitHub disconnected): three centered 480px sections — Edit account / GitHub connection / Cancel my account — each with its own eyebrow + h-section heading and a `section-rule` separator above the GitHub and danger sections.
- [ ] All form inputs render with `field-input` borders, focus ring, and label tone matching `/users/sign_up`.
- [ ] "Update account" submit is `btn--accent` (orange).
- [ ] "Connect GitHub" is `btn--outline`; clicking it triggers the OAuth flow exactly as before.
- [ ] After connecting GitHub: the GitHub section now shows "Connected as @username" with a styled link and "Disconnect GitHub" as `btn--danger`. Clicking it shows the existing turbo confirm and disconnects.
- [ ] "Cancel my account" is `btn--danger`. The turbo confirm dialog still appears before deletion.
- [ ] Submitting the form with a bad email surfaces the styled `notice-strip--err` errors panel above the email field — no regression vs sign-up.
- [ ] Submitting a valid update redirects back to `/users/edit` (Devise default) and re-renders the styled page with the success flash.
- [ ] No emoji, no hardcoded hex, no inline `style="color: #..."` — all colors via CSS custom properties.

**Implementation Note**: After this phase, all four target files are styled (`_links.html.erb`, `passwords/new.html.erb`, `passwords/edit.html.erb`, `registrations/edit.html.erb`). Run `git diff --stat` and confirm only those four paths plus zero unrelated files were changed.

---

## Testing Strategy

### Automated
- Existing controller tests (`test/controllers/users/registrations_controller_test.rb`) and integration tests (`test/integration/github_oauth_test.rb`) cover the controller paths that render these templates. Any ERB syntax error or missing local will surface as a test failure.
- No new automated tests are introduced — visual styling is not amenable to unit/integration assertions, and system tests are off-limits per `project_verify_no_system_tests.md`.

### Manual
1. `bin/rails server` and walk all in-scope routes:
   - `/users/sign_up` (Phase 1 regression check)
   - `/users/sign_in` (Phase 1 regression check)
   - `/users/edit` (Phase 3, both GitHub-connected and disconnected states)
   - `/users/password/new` (Phase 2)
   - `/users/password/edit?reset_password_token=invalid` (Phase 2 — invalid token still renders the form; submit it to see the styled error)
2. Trigger validation errors on each form to verify the `_error_messages` notice-strip continues to render correctly inside the new layout.
3. Verify the omniauth button styling on `/users/sign_in` (rendered by `_links`) — the `<form>` wrapper is `align-self: flex-start` (shrinks to button width), button is `btn--outline btn--sm`, and the gap to the previous link is roughly the parent's 6px plus the form's 6px margin-top.
4. Compare side-by-side with `/users/sign_in` and `/users/sign_up` to confirm visual parity in column width, vertical rhythm, type tone.

## Performance Considerations

None. Template-only changes; no new queries, partials, or assets.

## Migration Notes

None. No schema, route, or controller changes.

## References

- Research: `thoughts/shared/research/2026-05-08/users-edit-unstyled.md`
- Reference template (styled): `app/views/devise/registrations/new.html.erb:1-59`
- Reference template (styled): `app/views/devise/sessions/new.html.erb:1-32`
- Hifumi tokens / components: `app/assets/tailwind/application.css:131,153,289-329,334,343,358,360,681`
- Hifumi rollout commit (the one that skipped these files): `6c9234d` (2026-05-01)
- Convention: CLAUDE.md → "Conventions / Design system: Hifumi"
- Architecture doc: `docs/02-architecture/04-design-system.md` (token map + component-to-view inventory)
