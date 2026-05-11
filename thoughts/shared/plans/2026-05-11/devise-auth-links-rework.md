---
date: 2026-05-11
author: Paweł Strzałkowski
status: ready
topic: "Devise auth screens — remove omniauth button, replace cross-screen link stack with contextual prompts, inline forgot-password link"
research: thoughts/shared/research/2026-05-11/devise-auth-views-github-button-and-nav-links.md
---

# Devise auth-screen secondary-links rework

## Overview

Replace the current flat stack of unguarded cross-screen anchors + broken "Sign in with Github" `button_to` (`app/views/devise/shared/_links.html.erb:1-28`) with a single contextual prompt per page, and move "Forgot your password?" from the trailer block into an inline link next to the password field on `/users/sign_in`. Goal: no more duplication with the top nav, no more broken-OAuth button on sign-up, and a clearer per-page navigation cue.

## Current State Analysis

Source of truth: `thoughts/shared/research/2026-05-11/devise-auth-views-github-button-and-nav-links.md`.

- One shared partial (`app/views/devise/shared/_links.html.erb`) is rendered below an `<hr class="section-rule">` on **all four reachable Devise screens**: `registrations/new`, `sessions/new`, `passwords/new`, `passwords/edit`. (Plus two unreachable stubs: `confirmations/new.html.erb`, `unlocks/new.html.erb` — User is not `:confirmable` / `:lockable`, so no routes exist for them.)
- The partial emits a stack of up to three bare `link_to` anchors (Log in / Sign up / Forgot your password) guarded by `controller_name`, plus a `button_to "Sign in with Github"` with **no** controller guard.
- The omniauth callback (`app/controllers/users/omniauth_callbacks_controller.rb:2`) has `before_action :authenticate_user!`, so the GitHub button on sign-up / sign-in / passwords is functionally non-functional for sign-in — it always assumes an authenticated user and writes a `GithubConnection` row.
- The signed-out top nav (`app/views/layouts/application.html.erb:39-43`) already shows "Log in" + an orange "Sign up" pill on every page. The body partial duplicates one or both of those on every Devise screen.
- The 2026-05-08 styling plan explicitly flagged the GitHub button as broken-for-sign-in and put fixing/hiding it out of scope for that pass (`thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md:43, 54-55`).
- The `/users/edit` page has its own "Connect GitHub" button (`app/views/devise/registrations/edit.html.erb:84-85`) using the same authorize endpoint — that path is the legitimate place to start the GitHub OAuth flow and is unaffected by this plan.

## Desired End State

After this plan:

1. `_links.html.erb` emits **exactly one** contextual prompt per page, no omniauth button, no multi-link stack.
   - `registrations/new` → "Already have an account? Log in →"
   - `sessions/new` → "New here? Create an account →"
   - `passwords/new` and `passwords/edit` → "Remembered your password? Log in →"
   - Other controllers (the unreachable `confirmations` / `unlocks` stubs and any future Devise screen) → render nothing.
2. `/users/sign_in` has a small inline "Forgot your password?" link aligned right of the password label.
3. The "Sign in with Github" button no longer appears on any auth screen.
4. The top nav, the `/users/edit` GitHub section, and the omniauth callback are unchanged. The `/users/edit` "Connect GitHub" flow continues to work end-to-end (covered by existing `test/integration/github_oauth_test.rb`).
5. New integration tests cover the four reachable Devise screens — one assertion per page-branch (prompt present + omniauth button absent), plus inline-forgot present on sessions.

### Key Discoveries
- Body trailer is a uniform 3-line block in every view (`app/views/devise/registrations/new.html.erb:54-58`, `app/views/devise/sessions/new.html.erb:26-30`, `app/views/devise/passwords/new.html.erb:16-20`, `app/views/devise/passwords/edit.html.erb:27-31`) — only the partial content needs to change, not the wrapper.
- The partial's anchors are unclassed and inherit the global `<a>` style (per the 2026-05-08 styling pass). The new prompt link should follow the same convention — no class, parent `style="font-size: 20px;"` on the flex container drives sizing.
- `.field-label` is `display: block`, mono caps, 18px, with `margin-bottom: 4px`. To put it in a `flex items-center justify-between` row with an aux link we override `margin-bottom: 0` on the label and add the 4px on the row wrapper instead.
- `new_password_path(resource_name)` resolves to `/users/password/new` for the User mapping — same helper the partial currently uses.
- `Devise.token_generator.generate(User, :reset_password_token)` returns `[raw_token, encoded_token]`; setting `user.reset_password_token = encoded` and `user.reset_password_sent_at = Time.current`, then visiting `edit_user_password_path(reset_password_token: raw)` renders the reset form without triggering Devise's invalid-token redirect.

## What We're NOT Doing

- Not deleting the two unreachable stub views (`app/views/devise/confirmations/new.html.erb`, `app/views/devise/unlocks/new.html.erb`). The partial's new switch falls through to empty on those `controller_name` values; they continue to render harmlessly.
- Not touching the signed-out top-nav CTAs in `app/views/layouts/application.html.erb`.
- Not touching `/users/edit`'s "Connect GitHub" / "Disconnect" UI in `app/views/devise/registrations/edit.html.erb`.
- Not modifying the omniauth callback (`app/controllers/users/omniauth_callbacks_controller.rb`) or the OmniAuth config (`config/initializers/devise.rb:279-282`). GitHub OAuth remains available for already-signed-in users via `/users/edit`.
- Not adding anonymous "Sign in with GitHub" — separate, larger decision.
- Not changing the trailer wrapper (`<hr class="section-rule">` + flex-col render block) in any view file. Diff stays minimal.
- Not touching `app/views/devise/registrations/edit.html.erb` — it never rendered `_links`.

## Implementation Approach

One atomic commit. Three files change: the partial, the sessions view, and a new test file. The partial change drives the visible behaviour on all four screens at once; the sessions view change adds the inline forgot link; the test file pins both behaviours and catches regressions of the "Sign in with Github" copy returning.

---

## Phase 1: Rework Devise shared links partial + inline forgot-password link

### Commit
`auth: replace cross-screen link stack with contextual prompts, drop broken Sign-in-with-Github button`

### Overview
Rewrite `_links.html.erb` to emit a single per-page contextual prompt via `case controller_name`. Wrap the sessions/new password label in a justify-between row with an inline "Forgot your password?" link. Add `test/integration/devise_auth_links_test.rb` asserting one branch per Devise screen.

### Changes Required:

#### 1. Devise shared links partial — replace whole body
**File**: `app/views/devise/shared/_links.html.erb`
**Changes**: Replace the entire 28-line body with a single `case controller_name` switch. Drops the omniauth `button_to` block, the multi-link stack, and the inert confirmable/lockable branches.

```erb
<% case controller_name %>
<% when "registrations" %>
  <%= link_to "Already have an account? Log in →", new_session_path(resource_name) %>
<% when "sessions" %>
  <%= link_to "New here? Create an account →", new_registration_path(resource_name) %>
<% when "passwords" %>
  <%= link_to "Remembered your password? Log in →", new_session_path(resource_name) %>
<% end %>
```

Rationale per memory `feedback_no_logic_in_views.md`: the conditional here is presentation-only (which copy goes on which auth screen) and depends on framework state (`controller_name`), not domain — leaving it inline in the partial is the right home; extracting to a helper would create indirection for a one-call-site switch.

#### 2. Sessions/new — inline "Forgot your password?" link
**File**: `app/views/devise/sessions/new.html.erb`
**Changes**: Replace the existing password field `<div>` block (lines 11-14) with a justify-between row containing the label + an inline `link_to`, then the input below.

Before (lines 11-14):
```erb
<div>
  <%= f.label :password, class: "field-label" %>
  <%= f.password_field :password, autocomplete: "current-password", class: "field-input" %>
</div>
```

After:
```erb
<div>
  <div class="flex items-center justify-between" style="margin-bottom: 4px;">
    <%= f.label :password, class: "field-label", style: "margin-bottom: 0;" %>
    <%= link_to "Forgot your password?", new_password_path(resource_name), style: "font-size: 18px;" %>
  </div>
  <%= f.password_field :password, autocomplete: "current-password", class: "field-input" %>
</div>
```

No other changes to this view. The trailer block (lines 26-30) keeps rendering the partial — it will now emit the "New here? Create an account →" prompt.

#### 3. Integration test — pin behaviour
**File**: `test/integration/devise_auth_links_test.rb` (new)
**Changes**: One test per reachable Devise screen, each asserting (a) the new contextual prompt is present, (b) the literal string "Sign in with Github" is absent. The sessions test additionally asserts the inline "Forgot your password?" link is present and points at `new_user_password_path`. The passwords/edit test seeds a reset token via `Devise.token_generator`.

```ruby
require "test_helper"

class DeviseAuthLinksTest < ActionDispatch::IntegrationTest
  test "sign-up page shows log-in prompt and no GitHub button" do
    get new_user_registration_path
    assert_response :success
    assert_match "Already have an account?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "sign-in page shows sign-up prompt, inline forgot link, and no GitHub button" do
    get new_user_session_path
    assert_response :success
    assert_match "New here?", response.body
    assert_select "a[href=?]", new_user_registration_path, text: /Create an account/
    assert_select "a[href=?]", new_user_password_path, text: "Forgot your password?"
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "forgot-password page shows log-in prompt and no GitHub button" do
    get new_user_password_path
    assert_response :success
    assert_match "Remembered your password?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "reset-password page (with valid token) shows log-in prompt and no GitHub button" do
    user = User.create!(
      email: "reset@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "R", last_name: "U",
        openrouter_api_key: "sk-or-reset-12345678901234"
      }
    )
    raw, encoded = Devise.token_generator.generate(User, :reset_password_token)
    user.update!(reset_password_token: encoded, reset_password_sent_at: Time.current)

    get edit_user_password_path(reset_password_token: raw)
    assert_response :success
    assert_match "Remembered your password?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end
end
```

### Success Criteria:

#### Automated Verification:
- [x] New test file passes: `bin/rails test test/integration/devise_auth_links_test.rb`
- [x] Existing OAuth flow tests still pass (callback unchanged): `bin/rails test test/integration/github_oauth_test.rb`
- [x] Existing registration tests still pass (form unchanged): `bin/rails test test/controllers/users/registrations_controller_test.rb`
- [x] Full suite is green: `bin/rails test`

#### Manual Verification:
- [ ] `/users/sign_up` — single prompt "Already have an account? Log in →" below the section-rule; no "Sign in with Github" button anywhere on the page.
- [ ] `/users/sign_in` — small "Forgot your password?" link aligned right of the password label (same row, 18px); clicking it navigates to `/users/password/new`. Below the section-rule: single prompt "New here? Create an account →"; no "Sign in with Github" button.
- [ ] `/users/password/new` — single prompt "Remembered your password? Log in →" below the section-rule; no "Sign in with Github" button.
- [ ] `/users/password/edit` (open via a real reset email) — single prompt "Remembered your password? Log in →"; no "Sign in with Github" button.
- [ ] `/users/edit` (signed in) — "Connect GitHub" / "Disconnect GitHub" section continues to look and work the same.
- [ ] Top nav still shows "Log in" + "Sign up" pill on signed-out pages; "Account" + "Sign out" on signed-in pages. No visual regressions.
- [ ] Form layout on `/users/sign_in`: password label and inline forgot link are vertically aligned on one row, with the input below at the same horizontal start as the email input above. No misalignment on narrow viewports (≥ 360px).

**Implementation Note**: After automated verification passes, pause for manual confirmation before committing.

---

## Testing Strategy

### Unit Tests
N/A — change is presentation-only, no model / helper logic added.

### Integration Tests
Covered by `test/integration/devise_auth_links_test.rb` above. One test per page-branch (sign-up, sign-in, forgot, reset) — matching memory `feedback_test_branch_coverage.md`'s "one test per logical branch" rule. The reset-password branch uses `Devise.token_generator.generate` to seed a valid token without going through the mailer.

### Manual Testing Steps
1. Start dev server (`bin/dev`), open private window.
2. Visit each of the four reachable Devise screens listed under Manual Verification, confirm the per-page checklist.
3. From `/users/sign_in`, click the inline "Forgot your password?" link → confirm redirect to `/users/password/new`.
4. Sign in as an existing user (use a known dev account), visit `/users/edit`, confirm the "Connect GitHub" / "Disconnect" section is visually unchanged. (Don't need to actually complete the OAuth round-trip — covered by `github_oauth_test.rb`.)
5. Sign out, confirm top nav reverts to "Log in" + "Sign up" pill on all auth screens — no duplication framing now that the body uses contextual prompts.

## Performance Considerations

None — view-only change, no new queries, no new JS, no new asset.

## Migration Notes

None — no schema, no config, no environment changes.

## References

- Research: `thoughts/shared/research/2026-05-11/devise-auth-views-github-button-and-nav-links.md`
- Predecessor styling pass that flagged the broken button as out-of-scope: `thoughts/shared/plans/2026-05-08/style-unstyled-devise-views.md:43, 54-55`
- Phase 4a (auth + ownership): `thoughts/shared/plans/2026-04-28/phase-4a-auth-and-ownership.md`
- Existing OAuth callback test (must continue to pass): `test/integration/github_oauth_test.rb`
- Existing registration controller test (must continue to pass): `test/controllers/users/registrations_controller_test.rb`
- Design system reference: `docs/02-architecture/04-design-system.md`
- Affected files:
  - `app/views/devise/shared/_links.html.erb:1-28`
  - `app/views/devise/sessions/new.html.erb:11-14`
  - `app/views/devise/registrations/new.html.erb:54-58` (read-only — trailer unchanged)
  - `app/views/devise/passwords/new.html.erb:16-20` (read-only — trailer unchanged)
  - `app/views/devise/passwords/edit.html.erb:27-31` (read-only — trailer unchanged)
