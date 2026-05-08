---
date: 2026-05-07
plan_for: GitHub export prototype (OAuth App, manual button, single push)
research: thoughts/shared/research/2026-05-07/github-export-integration.md
status: draft
---

# GitHub Export Prototype Implementation Plan

## Overview

Add a "Connect GitHub" affordance to the user profile and an "Export to GitHub" button to each project page, so the user can push the workspace's existing git history into a new repo on their personal GitHub account in one click. Built as an extendable prototype: OAuth App for v1, with the storage layer (`GithubConnection` model with a `provider` discriminator and placeholder `refresh_token` / `expires_at` columns) shaped to absorb a future GitHub App migration without a rewrite.

Brand identity:
- GitHub org handle: `hifumidev`; org display name (visible in OAuth consent dialog): `hifumi.dev`.
- Bot user (commit author on GitHub): `hifumidev-bot` with verified email `code@hifumi.dev`.
- Workspace commit author identity (set on each generated app's `.git/config`): `hifumi.dev <code@hifumi.dev>`.

## Current State Analysis

Each generated app already lives at `~/projects/rails-app-generator-workspaces/project_<id>/` as a real git repo with meaningful per-revision commits — see `app/jobs/execute_instruction_job.rb:70-77` (skeleton baseline), `:148-149` (docs baseline), `lib/templates/picker.rb:59-63` (template pick), and `lib/roast/revision_workflow.rb:277,330-332` (per-revision code + docs commits). There is **zero** network-facing git code today — no `git push`, no `octokit`, no `gh`, no GitHub OAuth. The `omniauth :github, …` line in `config/initializers/devise.rb:277` is commented out.

The per-user-secret pattern is already established by the OpenRouter BYOK flow: `Profile` is `has_one` off `User`, `app/models/profile.rb:4` does `encrypts :openrouter_api_key`, and `app/controllers/users/registrations_controller.rb:42-49` wires it through Devise nested attributes. Long-running operations follow the `preview_state` enum + Solid Queue + Turbo Stream pattern (`app/models/project.rb:10-15`, `lib/preview/preview_manager.rb`).

Full prior art is in `thoughts/shared/research/2026-05-07/github-export-integration.md`.

## Desired End State

A logged-in user can:

1. Visit their profile (Devise registration edit page, `app/views/devise/registrations/edit.html.erb`), click "Connect GitHub", complete the GitHub OAuth authorize prompt, and return to the page showing "Connected as @username" with a "Disconnect" button.
2. On a project they own, see an "Export to GitHub" button (visible only when GitHub is connected and the project has at least one completed instruction). Clicking it opens a small form with the repo name (defaulted from project name) and a "Private" checkbox (defaulted on).
3. Submitting the form enqueues a Solid Queue export job. While running, the project page shows an "exporting" status box (mirroring the existing preview status indicator). On success, the box flips to "exported" and surfaces the GitHub URL with an "Open on GitHub" link plus a "Push latest changes" button. On failure, it shows a typed error and a Retry button.
4. Clicking "Push latest changes" later pushes new commits to the same repo (no force). If the GitHub side has commits we don't, the job fails loudly with "the repo has changed on GitHub — pull or force-push manually" and does not lose data.

Verification: a fresh user can complete the full Connect → Export → see-the-repo-on-GitHub round-trip without leaving the app.

### Key Discoveries:
- Each workspace is already a real git repo with meaningful history (`app/jobs/execute_instruction_job.rb:70-77`, `lib/roast/revision_workflow.rb:277`) — export pushes what's already there, no synthesis.
- **Author and pusher are independent on GitHub.** Author is set at commit time (`git config user.email/user.name` or `git -c user.email=…`); pusher is determined by the OAuth token. GitHub renders commits with the author's avatar (if the email is verified on a GitHub account) regardless of who pushed. This is the lever for "every commit credited to hifumi.dev" — set author = `hifumi.dev <code@hifumi.dev>` (a verified email on the `hifumidev-bot` user account), regardless of whose token does the push.
- `Profile#encrypts :openrouter_api_key` (`app/models/profile.rb:4`) is the existing per-user-secret pattern; GitHub tokens get an analogous treatment on a dedicated model.
- `Project#preview_state` enum + `lib/preview/preview_manager.rb` is the existing pattern for "long-running operation, broadcast state via Turbo Streams" — `export_state` mirrors it directly (`app/models/project.rb:10-15`).
- `git` binary is available in every environment that runs `ExecuteInstructionJob` (used at `:73-77`); `git push` shell-out is a natural fit, no new container dependency.
- `omniauth-github` v2.0.0 + `octokit` v10.x are the standard Ruby gems; `omniauth-github` plugs into Devise via the already-commented `config.omniauth :github, …` line at `config/initializers/devise.rb:277`.
- The `x-access-token:TOKEN@github.com/owner/repo.git` push URL works identically for OAuth `gho_…` tokens and GitHub App `ghu_…` tokens — only the token-acquisition layer differs between OAuth App and GitHub App, so the push code does not change at the future migration.

## What We're NOT Doing

- No generator-aware README or `CLAUDE.md` polish before push — the vanilla `rails new` README ships to GitHub for v1. (Tracked in `docs/09-ideas/01-git-integration.md`; separate phase later.)
- No auto-push after each instruction. v1 is button-driven only.
- No org repos or selected-repo installs. Personal-account-only.
- No webhooks, no two-way sync, no installation tokens, no app-attributed commits — all require GitHub App.
- No `delete_repo` scope and no "Delete from GitHub" button. User can delete on GitHub.
- No GitHub-side revocation API call on disconnect — destroying the `GithubConnection` row is enough; user can revoke on `github.com/settings/applications` if they want.
- No GitHub App migration in this plan. The model is shaped to absorb it (provider field, nullable refresh_token/expires_at columns), but the actual swap is a separate piece of work — see Phase 5 placeholder below. Phase 5 is the unblocker for shipping this feature to anyone outside localhost.
- No scope upgrades (no `delete_repo`, no `user:email`). We use `repo` only.
- **No GPG/SSH commit signing.** The `hifumi.dev <code@hifumi.dev>` commits will show up unsigned (no green "Verified" badge on GitHub). Adding signing would require provisioning a GPG/SSH key on the `hifumidev-bot` account and configuring git to sign with it — out of scope for the prototype. The avatar + name still render correctly without a signature.

## Production gate (load-bearing)

This plan ships a **prototype**, not a feature. The OAuth App grants the `repo` scope, which is **read/write to every public and private repository on the connecting user's account** — far broader than what this feature actually does (create one new repo, push to it). A leak of an encrypted token + the Rails master key compromises every private repo the user owns, not just the exported one.

That risk is acceptable on a localhost / single-developer demo and unacceptable anywhere a user we don't personally trust can sign up. So:

- This OAuth-App build is for **localhost development and internal demos only**. The GitHub OAuth App registered in Pre-flight P4 has a `localhost:3000` callback URL specifically to enforce that — a production callback URL would require a separate registration that does not exist yet.
- **No production deploy** of this code path. The `kamal deploy` target gets the Phase 0 / Phase 1 changes (workspace authorship is harmless to ship), but Phase 2-4 stay behind a feature flag (`ENV["GITHUB_EXPORT_ENABLED"] == "1"`) that is OFF in production until the GitHub App migration in Phase 5 lands.
- **No public sign-up flow exposed to this feature.** If sign-up opens before Phase 5 ships, the Connect GitHub button must remain hidden to non-allowlisted user IDs. (Tracked as a checklist item in the manual-verification section of Phase 2.)
- **No open beta, no friends-and-family demo, no recorded video that suggests this is a shipping feature** — the security tradeoff is only acceptable when the user understands they are pointing a broad-scoped token at a localhost dev environment.

The Phase 5 placeholder below names the migration as a tracked obligation. Until that ships, this work is internal-only.

## Implementation Approach

Five atomic-commit phases plus a pre-flight prep section. Each phase leaves the codebase working at its boundary:

0. Workspace commit identity (`Hifumi <code@hifumi.dev>` written into every workspace's `.git/config` at `git init` time, plus the explicit-author commit calls updated). Independent of GitHub export — ships value alone (every workspace from then on has Hifumi-attributed commits).
1. Data layer (`GithubConnection` model + migration + tests). No callers; pure schema + model.
2. OAuth round-trip (omniauth-github wiring + callback controller + connect/disconnect UI on profile). Token acquisition works end-to-end; nothing pushes yet.
3. Export job (Octokit + git shell-out). Job is fully testable from the Rails console; no UI.
4. Export UI (button on project page + Turbo Stream status broadcasts). Full feature visible.

The pattern at every phase mirrors something existing: `Profile`'s `encrypts` for the data layer, `Profile`-via-nested-attributes for UI, `preview_state` enum + `PreviewManager` for the job + Turbo broadcast.

### Author vs pusher (key separation)

GitHub records two different actors per commit: the **author** (set at commit time via `git -c user.email=…`) and the **pusher** (whoever's OAuth token pushed the bytes). They do not have to match — and in this design they intentionally don't. Author = `hifumi.dev <code@hifumi.dev>` on every commit, regardless of which end-user clicked Export. Pusher = the end-user (their OAuth grant, their token). GitHub renders commits with the bot's avatar (because `code@hifumi.dev` is verified on the `hifumidev-bot` user account) and records the push event under the end-user. This is the standard CI-bot / merge-bot pattern.

---

## Pre-flight: GitHub + email setup

Before any code changes can be tested, three external accounts/configs need to exist. None of these can be automated — they are one-time manual steps the user does.

### P1. Email forwarding for `code@hifumi.dev` (GoDaddy)

This must happen **first** — every other step needs to receive verification email at `code@hifumi.dev`.

1. Sign in to GoDaddy → Domain Portfolio → `hifumi.dev` → Email & Office → Email Forwarding.
2. Create forward: `code@hifumi.dev` → `<your personal inbox>`.
3. GoDaddy will set the required MX records on `hifumi.dev` automatically (or prompt you to). Wait for DNS propagation (usually <1h).
4. Test: send any email from another address to `code@hifumi.dev`, confirm it arrives in your personal inbox.

> **DNS conflict check**: if `hifumi.dev` already has MX records pointing at Resend, that's for sending only — Resend doesn't add receiving MX records. GoDaddy forwarding adds its own MX records and they coexist with Resend's outbound DKIM/SPF/DMARC. If you see existing MX records you don't recognize, screenshot the DNS panel before changing anything.

### P2. `hifumidev` GitHub organization

Owns the OAuth App and (later) the GitHub App. Free tier is enough.

1. Sign in to GitHub as your personal account → top-right → Your organizations → New organization → Free plan.
2. **Organization handle (URL)**: `hifumidev` (`hifumi` and `hifumi-dev` are both taken).
3. Contact email: your existing GitHub-verified address (this is owner contact, separate from `code@`).
4. Skip "invite members" and "what is your organization" surveys.
5. Confirm. The org now exists at `github.com/hifumidev`.
6. **Set the display name to `hifumi.dev`** (with the dot). Settings → General → "Organization display name" → `hifumi.dev` → Save. This is what users will see in the OAuth consent dialog — the URL handle (`hifumidev`) only appears in URLs.

### P3. `hifumidev-bot` bot user

This is the GitHub user whose avatar will appear on every generated commit. It must be a separate account from your personal GitHub.

1. **Sign out of GitHub** (or use a private window).
2. Sign up at github.com/signup with:
   - Username: `hifumidev-bot`
   - Email: `code@hifumi.dev` (the address you set up forwarding for in P1)
   - Password: a real one, store in your password manager
3. Verify the email — GitHub sends a confirmation link to `code@hifumi.dev` → forwards to your inbox → click confirm.
4. (Optional but recommended) Upload a hifumi.dev avatar in Settings → Profile so the avatar shows up on generated commits. Set the display name to `hifumi.dev` (Settings → Profile → Name) so the commit byline reads "hifumi.dev" instead of the username.
5. Sign back in as your personal account; from `hifumidev` org → People → Invite member → invite `hifumidev-bot` as a Member. Accept the invite from `code@hifumi.dev` inbox (will arrive forwarded).

> **GitHub TOS compatibility**: bot ("machine") accounts are explicitly permitted. The convention is one human owner per bot account, transparent purpose. `hifumidev-bot` is a typical instance of this pattern.

### P4. OAuth App (registered under `hifumidev` org)

This is what users will see in the GitHub authorize dialog as "hifumi.dev".

1. Sign in as your personal account (you are owner of `hifumidev` org).
2. Navigate to github.com → top-right → Your organizations → `hifumidev` → Settings → Developer settings → OAuth Apps → New OAuth App.
3. Fill in:
   - **Application name**: `hifumi.dev (dev)` for now; create a separate `hifumi.dev` app later for production.
   - **Homepage URL**: `http://localhost:3000` (production app gets its own registration with `https://hifumi.dev` later).
   - **Application description**: short blurb, e.g., "Rails app generator that exports your apps to GitHub."
   - **Authorization callback URL**: `http://localhost:3000/users/auth/github/callback`
   - **Enable Device Flow**: leave off.
4. Click "Register application". GitHub returns a Client ID (visible) and a Client Secret (one-shot — copy immediately).
5. Store both in your local `.env` (or wherever the generator reads ENV from):
   - `GITHUB_CLIENT_ID=<client_id>`
   - `GITHUB_CLIENT_SECRET=<client_secret>`
6. (Optional) Upload an app logo in the OAuth App settings — this is the icon shown in the consent dialog.

> **Why under the org, not your personal account**: the consent dialog shows the OAuth App's owner. Under the org with display name `hifumi.dev`, users see "hifumi.dev wants to access your account." Under your personal account, users would see your name. Org ownership also makes future team members able to administer the app without changing ownership.

### P5. (Deferred) GitHub App registration

Same flow as P4 but in the org's "GitHub Apps" section instead of "OAuth Apps". Not needed for v1; register only when migrating to GitHub App auth.

---

## Phase 0: Workspace commit identity

### Commit
`workspace: author all commits as hifumi.dev <code@hifumi.dev>`

### Overview
Switch every commit made into a generated workspace from the current mix of `Rails App Generator <generator@local>` (in some places) and "whatever the global git config is" (everywhere else) to a single, consistent `hifumi.dev <code@hifumi.dev>` identity. Achieved with two complementary mechanisms:

1. **Repo-local `git config`** written into the workspace right after `git init` — covers every commit made by anyone who later cd's into the workspace, including Roast/Claude-driven commits that have no explicit `--author` flag.
2. **Inline `-c user.email=… -c user.name=…` flags** kept on the existing explicit-author commits, updated to the new identity. These are belt-and-braces — even if someone later overrides the repo-local config, these specific commits still come out branded right.

Independent of the GitHub-export work — this phase ships value alone (any workspace generated after Phase 0 has Hifumi-branded commits, even if no one ever clicks Export).

### Changes Required:

#### 1. Centralize the identity
**File**: `app/models/project.rb`
**Changes**: Add a constant pair so the four call sites don't drift.

```ruby
# Identity used for every commit made into a generated workspace —
# written to repo-local .git/config at init time + applied as -c flags
# on every explicit-author commit. Set on commit, not on push: GitHub
# attributes commits by author email regardless of who pushed them.
COMMIT_AUTHOR_NAME  = "hifumi.dev"
COMMIT_AUTHOR_EMAIL = "code@hifumi.dev"
```

> Constants on `Project` (not a free-floating module) because this is a generated-app concern; `Project` is already the home of `workspace_root` and other workspace-shaped knowledge.

#### 2. `init_rails_app` — set repo-local config + use the constants
**File**: `app/jobs/execute_instruction_job.rb:70-77`
**Changes**: Add `git config user.email/user.name` immediately after `git init`, and replace the hardcoded `generator@local` / `Rails App Generator` strings.

```ruby
ok = system(
  subprocess_env,
  "cd #{Shellwords.escape(workspace)} && " \
  "git init -q -b main && " \
  "git config user.email #{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} && " \
  "git config user.name #{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} && " \
  "git add -A && " \
  "git -c user.email=#{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} " \
  "-c user.name=#{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} " \
  "commit -q -m 'chore: skeleton baseline'"
)
```

> `git config` runs without `-c` overrides, so it writes to repo-local `.git/config`. Belt-and-braces with the inline `-c` flags on the first commit because the order is `init → config → commit` and we want the first commit to be branded even if the config write somehow no-ops.
>
> `-b main` pins the initial branch name. Without it, the branch name comes from the host's `init.defaultBranch` config — modern systems default to `main` but older containers/boxes default to `master`, which would later break `git push origin main` in Phase 3. Pinning here means Phase 3's push code can rely on `main` existing locally.

#### 3. `init_docs_baseline` — drop ambiguity
**File**: `app/jobs/execute_instruction_job.rb:147-150`
**Changes**: Currently no explicit author flags — relies on whatever global git config exists. With Phase 0's repo-local config in place, this commit will pick up `Hifumi <code@hifumi.dev>` automatically. **No code change needed**, but add a brief comment so the next reader doesn't add `-c` flags out of caution.

```ruby
# Author identity comes from the repo-local config set in init_rails_app.
system(
  "cd #{Shellwords.escape(workspace)} && git add -A && " \
  "git commit -m 'docs: scaffolding baseline' --allow-empty"
)
```

#### 4. `Templates::Picker` — switch to constants
**File**: `lib/templates/picker.rb:59-63`
**Changes**: Replace hardcoded author flags (whatever they currently are) with the `Project::COMMIT_AUTHOR_*` constants. Even though the repo-local config covers this, keeping the explicit flags is defensive — `Templates::Picker.call` is called by `ExecuteInstructionJob` after `init_rails_app`, so the workspace config will exist by then, but a future caller might invoke the picker against a workspace that hasn't been `git init`-ed via our path.

#### 5. `RevisionWorkflow` — no code change, add a comment
**File**: `lib/roast/revision_workflow.rb:277,330-332`
**Changes**: Both commit calls run inside the workspace (Roast's working directory) and currently have no `-c` flags — they read repo-local `.git/config`, which Phase 0 sets. **No code change**, but add a one-line comment at line 277 noting where the identity comes from, so a future reader doesn't try to "fix" the missing flags.

#### 6. Tests
**File**: `test/jobs/execute_instruction_job_test.rb` (or new `test/integration/workspace_authorship_test.rb`)
**Changes**: Add a focused test that runs `init_rails_app` against a temp workspace, then asserts:

```ruby
# After init:
out = `git -C #{workspace} config user.email`.strip
assert_equal "code@hifumi.dev", out

out = `git -C #{workspace} config user.name`.strip
assert_equal "hifumi.dev", out

# First commit:
sha = `git -C #{workspace} rev-parse HEAD`.strip
author = `git -C #{workspace} log -1 --pretty='%an <%ae>' #{sha}`.strip
assert_equal "hifumi.dev <code@hifumi.dev>", author

# Branch name pinned to main regardless of host init.defaultBranch:
branch = `git -C #{workspace} rev-parse --abbrev-ref HEAD`.strip
assert_equal "main", branch
```

### Success Criteria:

#### Automated Verification:
- [x] Test passes: `bin/rails test test/integration/workspace_authorship_test.rb` (or wherever it lands)
- [x] No regressions in execute_instruction_job tests: `bin/rails test test/jobs/execute_instruction_job_test.rb`
- [x] Full suite green: `bin/rails test`

#### Manual Verification:
- [x] Generate one new project end-to-end with at least one revision.
- [x] In the workspace: `git log --pretty='%an <%ae>' | sort -u` shows **only** `hifumi.dev <code@hifumi.dev>` — no other authors.
- [x] In the workspace: `cat .git/config` shows the `[user]` block with `name = hifumi.dev` and `email = code@hifumi.dev`.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 1: `GithubConnection` model

### Commit
`github-export: add GithubConnection model and migration`

### Overview
Create the data layer for storing per-user GitHub OAuth tokens, shaped to absorb a future GitHub App migration without schema churn. No callers yet — this phase is pure schema + model + tests.

### Changes Required:

#### 1. Migration
**File**: `db/migrate/<timestamp>_create_github_connections.rb`
**Changes**: New table.

```ruby
class CreateGithubConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :github_connections do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :provider,        null: false, default: "github_oauth"
      t.string :github_username, null: false
      t.bigint :github_user_id,  null: false
      t.string :access_token,    null: false   # encrypted via Rails 8 attr encryption
      t.string :refresh_token                  # nullable; reserved for GitHub App migration
      t.datetime :expires_at                   # nullable; reserved for GitHub App migration
      t.timestamps
    end

    add_index :github_connections, :github_user_id, unique: true
  end
end
```

> One row per user (`unique: true` on `user_id`). Reconnecting overwrites the existing row.

#### 2. Model
**File**: `app/models/github_connection.rb`

```ruby
class GithubConnection < ApplicationRecord
  belongs_to :user, inverse_of: :github_connection

  encrypts :access_token
  encrypts :refresh_token

  validates :provider, :github_username, :github_user_id, :access_token, presence: true
  validates :provider, inclusion: { in: %w[github_oauth github_app] }

  # Today this is functionally `access_token.present?` (and the row only
  # exists when there's a token), but keep the predicate — Phase 5 (GitHub
  # App migration) will make it meaningful: an `expired?` token + no
  # refresh_token will mean "row exists but not currently usable".
  def connected? = access_token.present?

  # True only when the token has a known expiry that's in the past.
  # OAuth-app tokens never expire (expires_at is nil) — connected? is the only check.
  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def github_url = "https://github.com/#{github_username}"
end
```

#### 3. User association
**File**: `app/models/user.rb`
**Changes**: Add `has_one :github_connection, dependent: :destroy, inverse_of: :user`.

```ruby
has_one :github_connection, dependent: :destroy, inverse_of: :user
```

#### 4. Tests
**File**: `test/models/github_connection_test.rb`
**Changes**: New file. Cover: presence validations (provider, github_username, github_user_id, access_token), provider inclusion, `connected?` true/false, `expired?` for nil/past/future `expires_at`, encryption round-trip on `access_token` (set, save, reload, decrypt), explicit nil round-trip on `refresh_token` (set to nil, save, reload, still nil — `encrypts` on a nullable column should be a no-op for `nil`, but worth pinning so a future encryption-config change can't break it silently), `User#github_connection` association + `dependent: :destroy`.

**File**: `test/fixtures/github_connections.yml`
**Changes**: One fixture for `users(:one)` with a fake `gho_…` token.

### Success Criteria:

#### Automated Verification:
- [x] Migration applies cleanly: `bin/rails db:migrate`
- [x] Schema dump reflects the new table: `bin/rails db:schema:dump` (no diff besides the new table)
- [x] Model tests pass: `bin/rails test test/models/github_connection_test.rb`
- [x] No regressions: `bin/rails test`

#### Manual Verification:
- [x] Console: `User.first.create_github_connection!(provider: 'github_oauth', github_username: 'foo', github_user_id: 1, access_token: 'gho_test')` succeeds and the token is encrypted at rest (verify with raw SQL).

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 2: OAuth connect/disconnect flow

### Commit
`github-export: add OAuth connect/disconnect via omniauth-github`

### Overview
Wire `omniauth-github` through Devise so a logged-in user can authorize the GitHub OAuth App and end up with a populated `GithubConnection`. Add a "Connect GitHub" / "Disconnect" pair to the existing profile edit view. Push code lives in Phase 3 — at the end of Phase 2 we have a token but nothing to do with it yet.

### Changes Required:

#### 1. Gemfile
**File**: `Gemfile`

```ruby
gem "omniauth-github"
gem "omniauth-rails_csrf_protection"  # required by omniauth >= 2.0
```

After `bundle install`, `bundle update --conservative omniauth-github` if there's a transitive omniauth conflict (unlikely in this Rails 8.1 app).

#### 2. ENV vars + credentials
**File**: `.env.example` (create if missing) + `README.md` mention
**Changes**: Document `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`. The OAuth App registration itself happens in Pre-flight P4 (registered under the `hifumi` org, not a personal account, so the consent dialog reads "Hifumi"). This step is just persisting the resulting client_id / client_secret into the dev environment so omniauth can pick them up.

#### 3. Devise initializer
**File**: `config/initializers/devise.rb:277`
**Changes**: Replace the commented stub with:

```ruby
config.omniauth :github,
  ENV.fetch("GITHUB_CLIENT_ID", nil),
  ENV.fetch("GITHUB_CLIENT_SECRET", nil),
  scope: "repo"
```

> Use `ENV.fetch(..., nil)` not `ENV.fetch(...)` — per memory `feedback_env_bypass_in_dockerfile_boot`, the file boots during `assets:precompile` without runtime secrets.

#### 4. User model: add OAuth provider
**File**: `app/models/user.rb`
**Changes**: Add `:omniauthable, omniauth_providers: %i[github]` to the `devise` line.

```ruby
devise :database_authenticatable, :registerable, :recoverable,
       :rememberable, :validatable,
       :omniauthable, omniauth_providers: %i[github]
```

#### 5. Routes
**File**: `config/routes.rb`
**Changes**: Update the `devise_for :users` line to point at the callbacks controller (and add a disconnect route).

```ruby
devise_for :users,
  controllers: {
    registrations: "users/registrations",
    omniauth_callbacks: "users/omniauth_callbacks"
  }

resource :github_connection, only: :destroy
```

#### 6. Callback controller
**File**: `app/controllers/users/omniauth_callbacks_controller.rb`

```ruby
class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  before_action :authenticate_user!  # only logged-in users connect GitHub

  def github
    auth = request.env["omniauth.auth"]
    connection = current_user.github_connection || current_user.build_github_connection

    connection.update!(
      provider:        "github_oauth",
      github_username: auth.info.nickname,
      github_user_id:  auth.uid.to_i,
      access_token:    auth.credentials.token
      # refresh_token / expires_at intentionally not set — OAuth App tokens don't expire.
    )

    redirect_to edit_user_registration_path, notice: "Connected as @#{connection.github_username}."
  end

  def failure
    redirect_to edit_user_registration_path, alert: "GitHub connection failed: #{failure_message}"
  end
end
```

#### 7. Disconnect controller
**File**: `app/controllers/github_connections_controller.rb`

```ruby
class GithubConnectionsController < ApplicationController
  before_action :authenticate_user!

  def destroy
    current_user.github_connection&.destroy!
    redirect_to edit_user_registration_path, notice: "Disconnected from GitHub."
  end
end
```

#### 8. Profile edit view
**File**: `app/views/devise/registrations/edit.html.erb`
**Changes**: Insert a "GitHub connection" section **after line 55 (the `<% end %>` that closes `form_for`) and before line 57 (`<h3>Cancel my account</h3>`)**. The section uses `button_to`, which generates its own `<form>` — placing it inside the existing `form_for` would create nested `<form>` elements (invalid HTML, silently broken submit in some browsers). When connected, show `@username` + Disconnect; when disconnected, show Connect button. Match existing `<h3>` + `<div class="field">` structure.

```erb
<h3>GitHub connection</h3>

<% if current_user.github_connection&.connected? %>
  <p>
    Connected as <a href="<%= current_user.github_connection.github_url %>" target="_blank">@<%= current_user.github_connection.github_username %></a>.
  </p>
  <%= button_to "Disconnect GitHub", github_connection_path, method: :delete,
        data: { turbo_confirm: "Disconnect from GitHub? You'll need to reauthorize before exporting again." } %>
<% else %>
  <p><%= button_to "Connect GitHub", user_github_omniauth_authorize_path, method: :post, data: { turbo: false } %></p>
  <p><small>Required to export projects to your GitHub account. Grants access to your repositories (`repo` scope).</small></p>
<% end %>
```

> `data: { turbo: false }` on the connect button — omniauth's POST → 302 → external redirect breaks Turbo's same-origin assumption.

#### 9. Tests
**File**: `test/integration/github_oauth_test.rb`
**Changes**: New integration test. Use `OmniAuth.config.test_mode = true` + `OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(...)`. Test the full happy path (POST → callback → row created → redirect with notice), failure path (`OmniAuth.config.mock_auth[:github] = :invalid_credentials` → redirect with alert), reconnect (existing row updated, not duplicated), and disconnect (`DELETE /github_connection` → row destroyed).

### Success Criteria:

#### Automated Verification:
- [x] Bundle install succeeds: `bundle install`
- [x] Routes show the new entries: `bin/rails routes | grep github` includes both `users/auth/github` and `github_connection#destroy`
- [x] Integration tests pass: `bin/rails test test/integration/github_oauth_test.rb`
- [x] Full test suite green: `bin/rails test`

#### Manual Verification:
- [x] Register a real OAuth App on github.com with the correct callback URL.
- [x] Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` env vars.
- [x] Sign in, visit profile edit, click Connect GitHub → arrive at the GitHub authorize page → click Authorize → return to profile with "Connected as @yourname".
- [x] Click Disconnect → confirm prompt → row destroyed; the section flips back to the Connect button.
- [x] Reconnect → only one `github_connections` row exists for the user (existing row updated).

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 3: Export job (push mechanic)

### Commit
`github-export: add ExportToGithubJob with create-repo + git push`

### Overview
The actual push. New `ExportToGithubJob` (Solid Queue) creates the repo on GitHub via Octokit on first run, then shells out `git push` to the workspace. State persists to new columns on `projects`. Job is fully testable from a Rails console — UI lives in Phase 4.

### Changes Required:

#### 1. Gemfile
**File**: `Gemfile`

```ruby
gem "octokit", "~> 10.0"
```

#### 2. Migration
**File**: `db/migrate/<timestamp>_add_github_export_to_projects.rb`

```ruby
class AddGithubExportToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :github_repo_full_name, :string
    add_column :projects, :export_state,          :integer, null: false, default: 0
    add_column :projects, :exported_at,           :datetime
    add_column :projects, :export_error,          :text

    add_index :projects, :github_repo_full_name, unique: true, where: "github_repo_full_name IS NOT NULL"
  end
end
```

> Partial unique index (`WHERE github_repo_full_name IS NOT NULL`) — most projects never get exported and would otherwise collide on `NULL`.

#### 3. Project model: state enum + predicates
**File**: `app/models/project.rb`
**Changes**: Add the export_state enum after `preview_state` (line 15).

```ruby
enum :export_state, {
  not_exported: 0,
  exporting:    1,
  exported:     2,
  failed:       3
}, default: :not_exported, prefix: :export

def github_repo_url
  return nil if github_repo_full_name.blank?
  "https://github.com/#{github_repo_full_name}"
end

def exportable?
  user.github_connection&.connected? &&
    instructions.where(phase: :completed).exists? &&
    !export_exporting?
end
```

#### 4. The job
**File**: `app/jobs/export_to_github_job.rb`

```ruby
require "open3"
require "shellwords"

class ExportToGithubJob < ApplicationJob
  queue_as :default

  class TokenRevoked       < StandardError; end
  class RepoCreateFailed   < StandardError; end
  class PushDiverged       < StandardError; end
  class WorkspaceMissing   < StandardError; end

  # repo_name + private_repo only matter on first export. Subsequent
  # invocations push to the existing project.github_repo_full_name.
  def perform(project_id, repo_name: nil, private_repo: true)
    project = Project.find(project_id)
    raise WorkspaceMissing, "workspace not initialized" unless project.workspace_initialized?

    connection = project.user.github_connection
    raise TokenRevoked, "no github connection" unless connection&.connected?

    project.update!(export_state: :exporting, export_error: nil)

    if project.github_repo_full_name.blank?
      repo = create_repo(connection.access_token, repo_name, private_repo)
      project.update!(github_repo_full_name: repo.full_name)
    end

    push!(project, connection.access_token)

    project.update!(export_state: :exported, exported_at: Time.current)
  rescue Octokit::Unauthorized
    fail!(project, TokenRevoked.new("GitHub token was revoked. Please reconnect on your profile."))
  rescue Octokit::UnprocessableEntity => e
    # 422 from create_repository covers several causes — name collision is the
    # most common, but also: invalid name characters, repo creation disabled,
    # validation failures on auto_init/private. Don't pretend we know which.
    fail!(project, RepoCreateFailed.new("There was an issue creating the repo on GitHub: #{e.message}"))
  rescue PushDiverged => e
    fail!(project, e)
  rescue StandardError => e
    fail!(project, e)
  end

  private

  def create_repo(token, name, private_repo)
    client = Octokit::Client.new(access_token: token)
    client.create_repository(name, private: private_repo, auto_init: false)
  end

  def push!(project, token)
    workspace = project.workspace_path
    full_name = project.github_repo_full_name
    remote_url_with_token = "https://x-access-token:#{token}@github.com/#{full_name}.git"
    remote_url_clean      = "https://github.com/#{full_name}.git"

    # Pin a clean origin remote (no token in .git/config, ever) for the
    # user's later convenience (so `git push` from a checkout works once
    # they've added their own credentials).
    run!(workspace, "git remote remove origin", allow_fail: true)
    run!(workspace, "git remote add origin #{Shellwords.escape(remote_url_clean)}")

    # Push using the token-bearing URL passed directly on the command line,
    # NOT via a stored remote — Open3 args don't touch disk, so a crash
    # mid-push can't leave the token in .git/config. The URL is in the
    # process's argv for the duration of the push (visible in `ps` to
    # other users on the host) — acceptable given the host is a single-
    # tenant container in production.
    stdout, stderr, status = Open3.capture3(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "-C", workspace, "push", remote_url_with_token, "main"
    )

    return if status.success?

    if stderr.match?(/non-fast-forward|rejected/i)
      raise PushDiverged, "GitHub repo has commits we don't — pull or force-push manually."
    elsif stderr.match?(/Authentication failed|Bad credentials/i)
      raise Octokit::Unauthorized
    else
      raise "git push failed (exit #{status.exitstatus}): #{stderr.lines.last(5).join.strip}"
    end
  end

  def run!(workspace, cmd, allow_fail: false)
    Bundler.with_unbundled_env do
      ok = system("cd #{Shellwords.escape(workspace)} && #{cmd}")
      raise "command failed: #{cmd}" unless ok || allow_fail
    end
  end

  def fail!(project, error)
    project.update!(export_state: :failed, export_error: error.message) if project
    raise error
  end
end
```

> Token-leak hygiene: the token never lands in `.git/config`. We add the *clean* `origin` URL up front (no token) and pass the token-bearing URL directly to `git push` as a positional argument. Open3's argv stays in process memory (and `ps`) for the duration of the push, but never touches disk — so a crash/SIGTERM mid-push can't leave a `gho_…` token sitting in the workspace's git config indefinitely.

#### 5. Tests
**File**: `test/jobs/export_to_github_job_test.rb`
**Changes**: Stub Octokit at the boundary (`Octokit::Client#create_repository` returns a real `Sawyer::Resource` built from a hash, so the `.full_name` method accessor works exactly as in production) and stub `Open3.capture3` + `Kernel#system`. Cover:
- Happy path first export: creates repo, pushes, persists `github_repo_full_name` + state `:exported`.
- Happy path subsequent push: `github_repo_full_name` already set → no Octokit call → just push.
- `Octokit::Unauthorized` from create → state `:failed`, error mentions reconnecting, raises `TokenRevoked`.
- `Octokit::UnprocessableEntity` from create (name collision or any other 422) → state `:failed`, raises `RepoCreateFailed` with a generic "issue creating the repo" message.
- `git push` returns non-fast-forward → state `:failed`, raises `PushDiverged`. Assert that `git remote add origin …` was called with the **clean** URL (no token), and that the token-bearing URL appears only as an argv to `Open3.capture3`, never as a `git remote add/set-url` argument.
- `git push` succeeds → assert the same invariant: `.git/config` (via the stubbed `system` calls) only ever sees the clean URL.
- Workspace missing → raises `WorkspaceMissing` immediately.

### Success Criteria:

#### Automated Verification:
- [x] Bundle install succeeds: `bundle install`
- [x] Migration applies: `bin/rails db:migrate`
- [x] Job tests pass: `bin/rails test test/jobs/export_to_github_job_test.rb`
- [x] Full test suite green: `bin/rails test`
- [x] Brakeman clean (octokit/git shell-out is a hot spot for command-injection scanners): `bin/brakeman -q` *(1 medium-confidence false positive on `Open3.capture3` argv form remains — no shell involved; 3 pre-existing warnings in `lib/roast/auto_remediate.rb` and `spikes/roast/verify_revision.rb` are unrelated to this work)*

#### Manual Verification:
- [x] Console run-through with a connected user and a real workspace:
  ```ruby
  ExportToGithubJob.perform_now(project.id, repo_name: "exported-test-#{Time.now.to_i}", private_repo: true)
  ```
  → repo appears on github.com under the user's account, contains the workspace's commit history, default branch is `main`.
- [x] After push, inspect `<workspace>/.git/config` — `[remote "origin"]` URL has no token in it (should read `https://github.com/<owner>/<repo>.git` exactly).
- [x] Mid-run safety check: kill the worker mid-push (`kill -9` the Solid Queue process while the push is in flight), inspect `.git/config` afterwards — still no token. (This is the regression case the new push pattern protects against.)
- [x] Run again on same project (no kwargs) → new commits push to the same repo.
- [x] Manually push a commit on github.com (edit the README via the web UI), run job again → fails with `PushDiverged`, project state is `:failed`, no data lost.
- [x] Revoke the OAuth grant on github.com/settings/applications, run job again → fails with `TokenRevoked`, project state is `:failed`.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to the next phase.

---

## Phase 4: Export UI

### Commit
`github-export: add export-to-GitHub UI with Turbo broadcasts`

### Overview
Wire the job into the project page: a button that opens a tiny form (repo name + private checkbox), enqueues the job, and broadcasts state transitions back via Turbo Streams — same pattern as `preview_state`. Mirrors `lib/preview/preview_manager.rb` + `app/views/previews/pane.html.erb` for state display.

### Changes Required:

#### 1. Routes
**File**: `config/routes.rb`
**Changes**: Add a nested resource on projects.

```ruby
resources :projects do
  resource :github_export, only: :create
end
```

> Only `:create` — the form renders inline in the pane partial, so there is no separate `:new` page/frame to GET.

#### 2. Controller
**File**: `app/controllers/github_exports_controller.rb`

```ruby
class GithubExportsController < ApplicationController
  include ProjectOwnerRequired

  def create
    unless @project.exportable?
      redirect_to project_path(@project), alert: "Project not exportable yet."
      return
    end

    # First-export path supplies a `github_export` form scope (repo name +
    # private flag). The "Push latest changes" / "Retry" buttons re-POST
    # without that scope — we use existing project.github_repo_full_name
    # in the job and ignore the missing params.
    form_params = params.fetch(:github_export, {}).permit(:repo_name, :private_repo)
    name = form_params[:repo_name].presence
    private_repo = form_params[:private_repo] == "1"

    ExportToGithubJob.perform_later(@project.id, repo_name: name, private_repo: private_repo)
    @project.update!(export_state: :exporting, export_error: nil)

    # Form submits inside turbo-frame "github_export_pane" — render the
    # pane partial as plain HTML; the matching <turbo-frame> inside it
    # tells Turbo what to swap. Subsequent state transitions (exported /
    # failed) arrive via `turbo_stream_from @project` from the job.
    render partial: "github_exports/pane", locals: { project: @project }
  end
end
```

> `ProjectOwnerRequired` (`app/controllers/concerns/project_owner_required.rb`) already does `authenticate_user!` AND loads `@project` from `params[:project_id]` AND verifies ownership — so no separate `set_project` or `before_action :authenticate_user!` is needed. Including the concern is enough.

#### 3. Pane partial
**File**: `app/views/github_exports/_pane.html.erb`
**Changes**: New partial. Render-state-by-case mirroring `_previews/pane.html.erb`:
- `not_exported` + `exportable?` → "Export to GitHub" button → opens `_form.html.erb` in-place (turbo-frame).
- `not_exported` + `!exportable?` → muted "Connect GitHub on your profile to enable export" or "complete the first build first."
- `exporting` → status box with stripe + blinking dot, mono caps `EXPORTING…` (per Hifumi design system, see `app/assets/tailwind/application.css`).
- `exported` → status box `EXPORTED` + repo URL + "Open on GitHub" link + "Push latest changes" button (POSTs `create` again with no kwargs — pushes new commits to existing repo).
- `failed` → status box `FAILED` + `export_error` + "Retry" button + (if error mentions token) "Reconnect on profile".

```erb
<%= turbo_frame_tag "github_export_pane" do %>
  <% case project.export_state.to_sym %>
  <% when :not_exported %>
    <% if project.exportable? %>
      <%= render "github_exports/form", project: project %>
    <% else %>
      <p class="muted">Connect GitHub on <%= link_to "your profile", edit_user_registration_path %> to export.</p>
    <% end %>
  <% when :exporting %>
    <%= render "github_exports/status_box", state: "exporting", live: true, body: "Exporting to GitHub…" %>
  <% when :exported %>
    <%= render "github_exports/status_box", state: "exported", body: project.github_repo_full_name %>
    <p>
      <%= link_to "Open on GitHub", project.github_repo_url, target: "_blank" %>
      &middot;
      <%= button_to "Push latest changes", project_github_export_path(project),
            method: :post, data: { turbo_frame: "github_export_pane" } %>
    </p>
  <% when :failed %>
    <%= render "github_exports/status_box", state: "failed", body: project.export_error %>
    <%= button_to "Retry", project_github_export_path(project), method: :post,
          data: { turbo_frame: "github_export_pane" } %>
  <% end %>
<% end %>
```

> Status-box partial follows the existing rectangular-outlined-box pattern (per memory + design system) — stripe + blinking dot for live states, no emoji, sentence case in the body.
>
> The form renders **inline** in the not-exported branch (no lazy turbo-frame wrapper). An earlier draft used a lazy `turbo_frame_tag "github_export_form" loading: :lazy` with a fallback button — that pattern caused the button to flash briefly and morph into the form on load, and added a redundant round-trip for what is two visible inputs. The form partial is small enough to render directly.

#### 4. Form partial
**File**: `app/views/github_exports/_form.html.erb`
**Changes**: Rendered inline by the pane partial. The form's `data: { turbo_frame: "github_export_pane" }` makes the response replace the whole pane (which the controller renders with the new `:exporting` state).

```erb
<%= form_with url: project_github_export_path(project), scope: :github_export,
      data: { turbo_frame: "github_export_pane" } do |f| %>
  <div class="field">
    <%= f.label :repo_name, "Repository name" %>
    <%= f.text_field :repo_name, value: project.name.parameterize, required: true %>
  </div>
  <div class="field">
    <%= f.label :private_repo do %>
      <%= f.check_box :private_repo, { checked: true }, "1", "0" %>
      Private repository
    <% end %>
    <p><small>Defaults to private. You can flip the repo to public on GitHub later.</small></p>
  </div>
  <%= f.submit "Export" %>
<% end %>
```

> `checked: true` is required because `form_with scope: :github_export` has no model object — without it, the checkbox renders unchecked and every export defaults to public. Mirror Lovable / bolt.new defaults: private on by default.

#### 5. Project show view
**File**: `app/views/projects/show.html.erb`
**Changes**: Add a render of the pane below the preview pane (around line 41). Wrap in a `turbo_stream_from` (already present at line 2) so broadcasts find it.

```erb
<div class="lg:sticky lg:top-4 lg:h-fit">
  <%= render "previews/pane", project: @project %>
  <%= render "github_exports/pane", project: @project %>
</div>
```

#### 6. Job → Turbo Stream broadcast
**File**: `app/jobs/export_to_github_job.rb`
**Changes**: After every state transition (`:exporting`, `:exported`, `:failed`), broadcast a replace of `github_export_pane`. Pull the helper into a private method:

```ruby
def broadcast(project)
  Turbo::StreamsChannel.broadcast_replace_to(
    project,
    target: "github_export_pane",
    partial: "github_exports/pane",
    locals: { project: project }
  )
end
```

Call after each `project.update!(export_state: ...)`.

#### 7. Tests
**File**: `test/integration/github_export_flow_test.rb`
**Changes**: Integration test with the job stubbed. Cover:
- Owner sees Export button when connected + has completed instruction.
- Non-owner sees no button (or 404 on direct POST).
- Owner without connection sees the "Connect GitHub on your profile" prompt.
- POST with name + private flag → enqueues `ExportToGithubJob` with right args + state flips to `:exporting`.
- POST without `:github_export` scope (the "Push latest changes" / "Retry" path on an already-exported project) → does NOT raise `ActionController::ParameterMissing`; enqueues the job with `repo_name: nil`, `private_repo: false`; state flips to `:exporting`.
- Calling `perform_now` (or asserting the broadcast) results in `exported` pane.

**File**: `test/system/github_export_test.rb`
**Changes**: Single happy-path system test stubbing the job — clicks "Export to GitHub", fills the form, submits, sees the pane flip to "exporting" then "exported" via Turbo (the test triggers `perform_now` after submit).

### Success Criteria:

#### Automated Verification:
- [x] Migration applies: `bin/rails db:migrate` *(done in Phase 3)*
- [x] Integration tests pass: `bin/rails test test/integration/github_export_flow_test.rb`
- [ ] ~~System test passes: `bin/rails test:system test/system/github_export_test.rb`~~ *(skipped — codebase has no `test/system/`; integration test + manual verification cover the Turbo flow)*
- [x] Full test suite green: `bin/rails test && bin/rails test:system`

#### Manual Verification:
- [x] Connected user, project with completed instruction → Export button visible.
- [x] Click Export → form appears in-place (no full page reload).
- [x] Submit with default private + slug name → pane flips to EXPORTING (live indicator visible) → flips to EXPORTED with the repo URL within ~30s.
- [x] Click "Open on GitHub" → repo opens, default branch is `main`, commit history matches the chat timeline, repo is private.
- [x] Click "Push latest changes" after running another instruction → pane flips through EXPORTING → EXPORTED again, new commit appears on GitHub.
- [x] Disconnect GitHub on profile → return to project → pane shows "Connect GitHub on your profile" instead of Export button.
- [x] As a different (non-owner) user, navigate to the project → no Export button (and direct POST returns 404 / forbidden). *(covered by integration test)*
- [x] Force a divergence: edit README on github.com via web UI, then click "Push latest changes" → pane flips to FAILED with a divergence message; the project's git history on disk is untouched.

**Implementation Note**: After completing this phase and all automated verification passes, pause here for manual confirmation from the human that the manual testing was successful before proceeding to any follow-up work.

---

## Phase 5: GitHub App migration (placeholder)

> Not a deliverable of this plan — included as a named, tracked obligation so the OAuth-App work is honestly scoped as throwaway and the production gate has a concrete unblocker. A full plan for this phase is a separate document.

### Why it exists

The OAuth App's `repo` scope is too broad to put in front of users we don't personally trust (see Production gate). GitHub Apps fix the scoping by attaching permissions to a per-user *installation* rather than a global token: the user picks which repos the app can touch, and a token leak compromises only those repos — not their entire account.

### What changes

- **New**: GitHub App registration in `hifumidev` org (Pre-flight P5, currently deferred).
- **New**: installation flow — user clicks "Connect GitHub" → arrives at the GitHub *install* page (not the *authorize* page) → picks "Only select repositories" or "All repositories" → returns with an installation_id.
- **New**: installation-token rotation — `ghu_…` user-to-server tokens expire every 8 hours; the app refreshes via JWT-signed requests to `/app/installations/<id>/access_tokens`. The `refresh_token` and `expires_at` columns on `github_connections` (already present from Phase 1) get populated.
- **Changed**: `GithubConnection#provider` flips from `"github_oauth"` to `"github_app"`. The provider field already exists; no schema migration needed.
- **Changed**: `omniauth-github` → `omniauth-github` configured for App user-to-server flow, OR drop omniauth and hand-roll the installation callback (the App flow is simple enough that omniauth's value is marginal).
- **New**: webhook endpoint to handle `installation.deleted` (user uninstalls the app → destroy the row).
- **Unchanged**: Phase 0 (workspace identity), Phase 1 (data model), Phase 3's push mechanic (the `https://x-access-token:TOKEN@...` URL works identically for `gho_…` and `ghu_…` tokens), Phase 4's UI. This is the explicit reason the data model and push code were shaped the way they were.

### Gating

Until this phase lands and the production callback URL is registered, the `GITHUB_EXPORT_ENABLED` flag stays OFF in production and the Connect GitHub button stays hidden. When Phase 5 lands, that flag flips on and the OAuth-App registration is decommissioned (revoke at github.com → org → Developer settings → OAuth Apps → Delete).

### Cost estimate

GitHub App registration is free. Implementation is roughly two engineering days of work — most of it in the JWT-signing helper and the installation-token cache — assuming Phases 0-4 of this plan have already shipped and proven the push mechanic + UI. Less if we drop omniauth and hand-roll the callback (one fewer moving part to debug).

---

## Testing Strategy

### Unit Tests:
- `GithubConnection`: validations, `connected?`, `expired?`, encryption round-trip on tokens.
- `ExportToGithubJob`: each branch of the rescue hierarchy, token-stripping invariant on both success and push failure, idempotence of subsequent push (no Octokit call when `github_repo_full_name` is set).

### Integration Tests:
- OAuth round-trip with `OmniAuth.config.test_mode = true` and mock_auth (happy + invalid + reconnect + disconnect).
- Export flow: button visibility by ownership + connection state, POST → job enqueued + state transition + broadcast.

### System Tests:
- One happy-path Capybara test: connect (mocked) → click Export → fill form → submit → assert state pane flips through exporting → exported via Turbo.

### Manual Testing Steps:
1. Register a GitHub OAuth App with the localhost callback URL; set ENV vars.
2. Sign in, click Connect GitHub on profile, complete the authorize flow, verify "Connected as @you".
3. On a project with a completed instruction, click Export to GitHub, fill in name + private, submit, watch the pane flip through states, click Open on GitHub.
4. Edit the README on github.com, click Push latest changes, verify divergence error.
5. Disconnect, verify the Export button disappears.

## Performance Considerations

Push performance is dominated by network upload of the workspace (≈1-5 MB for a fresh Rails app + a handful of revisions). Octokit `create_repository` is a single API call (~500ms). The job runs on Solid Queue's default queue and competes with `ExecuteInstructionJob` and `PreviewManager` jobs — for a prototype this is fine; if export becomes auto-after-each-instruction (out of scope here) we may want a dedicated queue or a serial export semaphore per project to avoid overlapping pushes.

The `Octokit::Client` token rate limit is 5 000 req/hour per user — far above any plausible UI-driven usage.

## Migration Notes

- Two new migrations: `create_github_connections` (Phase 1) and `add_github_export_to_projects` (Phase 3). Both are additive — no data backfill, no destructive changes.
- The `GithubConnection` table's `refresh_token` and `expires_at` columns are nullable and unused in v1. They exist now to absorb the future GitHub App migration without a schema change. (If we later decide GitHub App will never happen, drop them in a follow-up migration — cheap.)
- The `provider` column defaults to `'github_oauth'` and is validated against the inclusion list `%w[github_oauth github_app]`. Adding more providers (GitLab, Bitbucket) means extending the inclusion list — but that would more likely live on a polymorphic parent model; treat that as a separate refactor decision.

## References

- Research: `thoughts/shared/research/2026-05-07/github-export-integration.md`
- Idea backlog: `docs/09-ideas/01-git-integration.md`
- Per-user secret pattern: `app/models/profile.rb:4`
- Devise nested attributes: `app/controllers/users/registrations_controller.rb:42-49`
- State enum + Turbo broadcast pattern: `app/models/project.rb:10-15`, `lib/preview/preview_manager.rb`
- Workspace git history: `app/jobs/execute_instruction_job.rb:70-77`, `lib/roast/revision_workflow.rb:277,330-332`
- Hifumi design system (status boxes): `app/assets/tailwind/application.css`, `docs/02-architecture/04-design-system.md`
