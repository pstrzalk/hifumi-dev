---
date: 2026-04-28
author: Paweł Strzałkowski (with Claude)
status: ready-for-implementation
phase: 4
part: a
scope: lean
predecessor_research: thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md
predecessor_plan: thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md
---

# Phase 4 — Production deploy on Hetzner with kamal-proxy + multi-tenancy
## Part A: Auth & Ownership (Phases 1–4)

> **Plan split into 4 parts (header duplicated in each):**
> - **A** (this file): Phases 1–4 — Devise + Profile, ownership FK, projects index + welcome root, per-user OpenRouter key
> - B: Phases 5–7 — preview lifecycle refactors (`phase-4b-preview-refactors.md`)
> - C: Phases 8–10 — production infrastructure (`phase-4c-deploy-infrastructure.md`)
> - D: Phases 11–13 + closing sections — deploy & wrap-up (`phase-4d-deploy-and-wrapup.md`)

## Overview

Deploy the generator publicly at `https://hifumi.dev` and serve every preview at its own subdomain `https://<id>.preview.hifumi.dev`, with strict egress isolation on a Linux Docker network and per-user OpenRouter API keys (BYOK) to keep operating cost off the deployer. Multi-tenancy via Devise + a separate `Profile` model. Public access via the preview hostname only (the live website itself is the share URL); the editing studio at `hifumi.dev/projects/:id` requires login + ownership. Co-exists with the three Kamal apps already running on the host (perfect_pitch, touchtype, blind_cv_generator).

This is the **Lean cut** of Phase 4 — explicitly defers per-container network subnets, wake-on-request, an explicit publish/unpublish gesture, multi-host LB, monitoring dashboards, and gVisor/Firecracker. Those become Phase 5 candidates.

## Current State Analysis

The codebase shipped Phase 3 on 2026-04-27 (commit `b91e34a`) at the local-PoC level. Everything below is *as-is*; the plan below changes it.

- **Auth:** none. Anyone hitting `localhost:3000` can create projects, send instructions, and start previews. Single-tenant by assumption.
- **Project ownership:** `Project` has no `user_id`. There is no `User` model.
- **OpenRouter key:** global `ENV["OPENROUTER_API_KEY"]` consumed by `config/initializers/ruby_llm.rb:2` and (via subprocess) by `bin/roast-openrouter`. One key for the whole app.
- **Preview URL:** `Project#preview_url` returns `"http://localhost:#{preview_port}"` where `preview_port = 3000 + id` (`app/models/project.rb:22-29`). Hard-coded to localhost.
- **Preview network:** `preview-internal` Docker network created **without** `--internal` (vpnkit limitation on Docker Desktop); host port-mapped via `-p`. `lib/preview/preview_manager.rb:77-83`, `:141-172`.
- **Preview routing:** none. iframe in the generator's UI loads `localhost:#{port}`.
- **Idle reaper:** `CleanupIdlePreviewsJob` runs every 5 min (`config/recurring.yml:14-16`), stops previews running >30 min unconditionally.
- **Generator deployment:** `Dockerfile` and `config/deploy.yml` are the Rails-default Kamal scaffolding, never used. Placeholder server `192.168.0.1`, registry `localhost:5555`, proxy block commented out.
- **Roast runner:** `bin/roast` (subscription, with frum + ANTHROPIC scrub), `bin/roast-openrouter` (paid, with OpenRouter env). `ExecuteInstructionJob:104` calls `bin/roast` unconditionally.
- **Boot orphan reset:** `config/initializers/preview_reset.rb` runs `Preview::PreviewManager.reset_orphans!` on `server`/`runner`/`console` boot. Removes all `preview-*` containers and flips all `:starting`/`:running` rows to `:stopped`.
- **Routes:** `root "projects#new"`. `resources :projects, only: [:new, :create, :show]` with nested `messages` and `preview`.
- **Existing Hetzner box:** `77.42.95.154`, 16 GB RAM, 150 GB disk, kamal-proxy v0.9.0 already running on 80/443 routing perfect_pitch / touchtype / blind_cv_generator. Local Docker registry on `localhost:5555`. `kamal` Docker network.

## Desired End State

After all 13 phases land:

- **Generator** runs on Hetzner under Kamal; reachable at `https://hifumi.dev`. SSL via kamal-proxy's built-in Let's Encrypt (HTTP-01).
- **Anonymous visitor at `hifumi.dev`** sees a welcome page with [Sign up] / [Log in] CTAs.
- **Logged-in user at `hifumi.dev`** is redirected to `/projects` showing their project list.
- **Each project** belongs to exactly one user; only the owner can view the studio (`/projects/:id`), send instructions, start/stop the preview, or delete it.
- **Preview live URL** at `https://<id>.preview.hifumi.dev` serves the running container's Rails app directly via kamal-proxy. No studio chrome. Public — anyone with the URL sees the live website. SSL fetched on first request (per-host LE cert).
- **Preview-stopped state** at the same URL: kamal-proxy returns its default no-route response (502/404). No branded offline page in Lean Phase 4 — kamal-proxy v0.9 doesn't support wildcard hostnames (verified — Kamal issue #1194 open with no resolution; HTTP-01 also can't validate wildcards), so falling through to the generator would require either DNS-01 + Caddy in front, or per-project always-registered routes that swap target on stop. Both are deferred to Phase 5.
- **Strict egress isolation:** preview containers run on a `--internal` Docker network; they cannot make outbound HTTP requests at runtime (gem dependencies must be baked at build time, which already happens).
- **Per-user OpenRouter key (BYOK):** each user enters their own OpenRouter API key during signup; that key is used for all LLM calls (chat replies via RubyLLM and Roast revisions via subprocess) on their projects. The deployer's wallet is never touched.
- **Three Kamal apps coexist** untouched on the same host (perfect_pitch, touchtype, blind_cv_generator).

### Verification

End-to-end manual smoke at the close of Phase 11:

1. Browse `https://hifumi.dev` (anonymous) → see welcome page.
2. Sign up with email + password + first name + last name + OpenRouter API key → land on `/projects` (empty list).
3. Create a project → studio loads → send first instruction → wait for completion → click Start preview.
4. Wait for `running` state → click iframe link → opens `https://<id>.preview.hifumi.dev` in a new tab → see live Rails app over HTTPS with valid cert.
5. In a private browser window, hit `https://<id>.preview.hifumi.dev` directly → see same live app (public).
6. In a private browser window, hit `https://hifumi.dev/projects/<id>` → redirected to login.
7. Log in as owner, click Stop preview → wait for `stopped` state → hit `https://<id>.preview.hifumi.dev` again → kamal-proxy returns its default no-route response (502/404). No branded page in Lean Phase 4.
8. From inside the running preview container (`docker exec`), `curl https://example.com` → fails (egress blocked).
9. perfect_pitch / touchtype / blind_cv_generator URLs all still respond.

## Key Discoveries

(See `thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md` for the full inventory.)

- **kamal-proxy is already running** on the box (`basecamp/kamal-proxy:v0.9.0`, 80/443) and routing 3 tenant apps. The "kamal-proxy install path" open question (research §Open Questions Q1) is solved for free. (`docker ps` on the host confirms.)
- **`bin/roast-openrouter` is already prod-safe** — it has no frum block, only OpenRouter env setup. Works inside a Docker container with locked Ruby. (`bin/roast-openrouter:1-15`.)
- **`PreviewManager` already has injectable `SystemRunner`** (`lib/preview/preview_manager.rb:20-26`); kamal-proxy CLI calls plug into the same `@runner.run(...)` shape.
- **`preview.ready` event already emitted** but not subscribed (`lib/preview/preview_manager.rb:48-51`); no subscriber addition needed for kamal-proxy registration — registration happens inline in `PreviewManager#start` before broadcast.
- **`config/initializers/preview_reset.rb` matches `bin/thrust ./bin/rails server`** because thrust execs into `rails server`, leaving `ARGV.first == "server"`. (`Dockerfile:CMD` confirms.) Boot reset works under Kamal without changes.
- **`Preview::PreviewManager.reset_orphans!` is a single-tenant nuker today** — it kills *every* `preview-*` container and resets *every* `:starting`/`:running` row on every Rails boot, with no concept of "this container belongs to a live DB row, leave it alone". Phase 4 (Phase 10 in this plan) rewrites it as a three-category reconciliation so a `kamal deploy` of the generator doesn't take down all live user previews. It also doesn't clean up kamal-proxy routes today; the rewrite removes the route alongside the container only for true orphans (category B).
- **Existing initializers list:** `config/initializers/preview_reset.rb` (boot reset), `config/initializers/event_subscribers.rb` (3 subscribers on `instruction.requested`), `config/initializers/ruby_llm.rb` (global RubyLLM config). Phase 4 adds `preview_config.rb`.
- **Skeleton overlay's `preview_iframe.rb`** strips `X-Frame-Options` from preview responses so the studio's iframe can load them cross-origin (`lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb`). Stays relevant in Phase 4 — generator and preview ARE different origins under hifumi.dev.

## What We're NOT Doing

Explicit scope-outs to prevent creep. Each maps to a Phase 5 (or later) candidate.

- **No per-container network subnets.** All previews share `preview-internal`; container-to-container reachability within that network is accepted (Phase 3 analysis line 339).
- **No wake-on-request for stopped previews.** When a preview is stopped, the public URL returns kamal-proxy's default no-route response; the owner has to click Start to bring it back.
- **No explicit publish/unpublish gesture.** Every running preview is publicly reachable; owner controls reachability via Start/Stop.
- **No idle-preview reaper.** Removed in Phase 5. Owner is responsible for stopping their preview when done. (Re-introduce as wake-on-request OR explicit publish in a future phase.)
- **No multi-host load balancing**, no second `job` role host, `SOLID_QUEUE_IN_PUMA: true` stays.
- **No backups** of the workspace tree or generator SQLite. Acceptable loss for a demo.
- **No monitoring dashboards / alerting** beyond Kamal's `kamal app logs` and `docker stats`.
- **No DNS-01 wildcard cert.** Per-preview HTTP-01 cert via kamal-proxy's built-in LE. If we hit the 50-unique-hosts/week LE rate limit, switch to DNS-01 in Phase 5.
- **No branded "App offline" page.** kamal-proxy v0.9 doesn't support wildcard hostnames in `--host` or `proxy.hosts` (verified: Kamal issue #1194 open, HTTP-01 also can't validate wildcards). Stopped-preview UX is whatever kamal-proxy serves by default (no-route 502/404). Phase 5 candidates: (a) per-project always-registered routes with target swap on start/stop, (b) Caddy in front of kamal-proxy doing DNS-01 + wildcard.
- **No removal of the existing three Kamal apps** on the box. They co-exist; kamal-proxy routes them by host.
- **No backwards-compatibility shims.** Existing dev DB is nuked (per decision); existing deferred observations from Phase 2 (refused-tool-call pill UX, deferred-request handling, Step 7 wall-time margin) remain deferred.
- **No fork-this-project / public commenting** flows.
- **No display name on Profile.** Only `first_name` + `last_name`. Skipped because no public-facing surface attributes a project to its owner under Lean Phase 4.
- **No model-selection UI.** Fixed at `anthropic/claude-haiku-4.5` via OpenRouter.
- **No Devise `:confirmable`** (email verification skipped — keeps Resend scope tight to password-reset only).
- **No Pundit / authorization gem.** Hand-rolled `before_action :require_owner!`.

## Implementation Approach

The plan splits into 6 logical groups:

- **Group A (Phases 1–3): Multi-tenancy in dev.** Devise + Profile + signup form, ownership FK + enforcement, projects index + root URL behavior. Each phase leaves dev runnable.
- **Group B (Phase 4): Per-user key threading.** ChatRespondJob + ExecuteInstructionJob both read `project.user.profile.openrouter_api_key`. Log scrubbing added.
- **Group C (Phases 5–7): Preview lifecycle + URL refactor.** Idle reaper removed, `Preview::Config` wrapper introduced, Roast wrappers renamed.
- **Group D (Phases 8–10): Production infrastructure.** Generator Dockerfile + deploy.yml, pre-deploy hook, PreviewManager prod additions (kamal-proxy register/remove + `--internal` flip).
- **Group E (Phase 11): Email + first deploy.** Resend SMTP + Devise mailer config, then initial deploy + manual smoke.
- **Group F (Phases 12–13): Docs.** Phase 4 retro doc + CLAUDE.md status update.

Each phase = one atomic commit that leaves the codebase working. Test-driven where the change is testable; the deploy-bootstrap phases (8, 9, 11) are config-only.

---

## Phase 1: Devise + User + Profile + nested signup form

### Commit
`phase 4 step 1: Devise + User + Profile multi-tenancy foundation`

### Overview

Add Devise for authentication, a `User` model (Devise schema), a separate `Profile` model with `first_name`, `last_name`, `openrouter_api_key` (encrypted), and a nested registration form that captures all five fields atomically. Profile is created via `accepts_nested_attributes_for`. No project changes yet — projects continue to work as single-tenant; this phase only stages the auth scaffolding.

### Changes Required

#### 1. Add Devise gem

**File:** `Gemfile`
**Changes:** Add `gem "devise"`.

```ruby
gem "devise"
```

Then `bundle install`.

#### 2. Generate Devise install + User model

**Commands:**

```bash
bin/rails generate devise:install
bin/rails generate devise User
```

Customize `config/initializers/devise.rb`:

- `config.mailer_sender = "noreply@hifumi.dev"` (Resend wires up in Phase 11; until then mailer falls back to default delivery method, which is `:test` in dev — fine).
- Leave defaults otherwise.

Edit the generated migration `db/migrate/<ts>_devise_create_users.rb` BEFORE running:

- Comment out / remove `:trackable`, `:confirmable`, `:lockable` columns (we're not using those modules).
- Keep `:database_authenticatable`, `:recoverable`, `:rememberable` columns.

Edit `app/models/user.rb`:

```ruby
class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable

  has_one :profile, dependent: :destroy, inverse_of: :user, autosave: true
  accepts_nested_attributes_for :profile

  validates :profile, presence: true   # invariant: a user has a profile from creation onwards;
                                       # signup form supplies it via nested attrs, console/fixture
                                       # paths MUST do the same — no silent auto-build later.

  has_many :projects, dependent: :destroy   # FK lands in Phase 2; declared here for forward compatibility
end
```

(`autosave: true` is set explicitly even though `accepts_nested_attributes_for` enables it implicitly — keeping it visible at the association line makes the load-bearing behavior obvious to readers and resilient to refactors that might later remove the nested-attrs declaration.)

#### 3. Set up Rails 8 attribute encryption (BEFORE the Profile model loads)

The `encrypts :openrouter_api_key` declaration on `Profile` raises `ActiveRecord::Encryption::Errors::Configuration` at class load time if keys aren't configured. So configure encryption *before* defining the model.

**Command:**

```bash
bin/rails db:encryption:init
```

Take the output (3 base64 keys) and add to credentials for dev + prod:

```bash
EDITOR=vim bin/rails credentials:edit
# paste the active_record_encryption: stanza emitted by db:encryption:init
```

Ensure `RAILS_MASTER_KEY` is preserved in `.gitignore` (it already is) and that `config/master.key` is present.

**Test environment** doesn't load credentials. Add non-secret deterministic keys directly to `config/environments/test.rb`:

```ruby
config.active_record.encryption.primary_key             = "test_primary_key_at_least_32_bytes"
config.active_record.encryption.deterministic_key       = "test_deterministic_key_32_bytes_l"
config.active_record.encryption.key_derivation_salt     = "test_key_derivation_salt_32_bytes"
```

Without this, the test suite fails the moment any test touches `Profile`.

#### 4. Generate Profile model

**Migration:** `db/migrate/<ts>_create_profiles.rb`

```ruby
class CreateProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :profiles do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :first_name
      t.string :last_name
      t.string :openrouter_api_key   # encrypted via Rails 8 attribute encryption
      t.timestamps
    end
  end
end
```

**File:** `app/models/profile.rb`

```ruby
class Profile < ApplicationRecord
  belongs_to :user, inverse_of: :profile

  encrypts :openrouter_api_key

  validates :first_name, :last_name, :openrouter_api_key, presence: true
end
```

#### 5. Custom Devise registrations controller for nested Profile

**File:** `app/controllers/users/registrations_controller.rb` (new)

```ruby
class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [:create]
  before_action :configure_account_update_params, only: [:update]

  def new
    build_resource({})
    resource.build_profile
    respond_with resource
  end

  private

  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up,
      keys: [profile_attributes: [:first_name, :last_name, :openrouter_api_key]])
  end

  def configure_account_update_params
    devise_parameter_sanitizer.permit(:account_update,
      keys: [profile_attributes: [:id, :first_name, :last_name, :openrouter_api_key]])
  end
end
```

**File:** `config/routes.rb`

Add at the top:

```ruby
devise_for :users, controllers: { registrations: "users/registrations" }
```

#### 6. Customize the registration view

**File:** `app/views/devise/registrations/new.html.erb` (generate via `bin/rails generate devise:views`, then edit)

Add the nested fields:

```erb
<%= form_for(resource, as: resource_name, url: registration_path(resource_name)) do |f| %>
  <%= devise_error_messages! %>

  <div><%= f.label :email %><%= f.email_field :email, autofocus: true, autocomplete: "email" %></div>
  <div><%= f.label :password %><%= f.password_field :password, autocomplete: "new-password" %></div>
  <div><%= f.label :password_confirmation %><%= f.password_field :password_confirmation, autocomplete: "new-password" %></div>

  <%= f.fields_for :profile do |pf| %>
    <div><%= pf.label :first_name %><%= pf.text_field :first_name %></div>
    <div><%= pf.label :last_name  %><%= pf.text_field :last_name %></div>
    <div>
      <%= pf.label :openrouter_api_key, "OpenRouter API key" %>
      <%= pf.password_field :openrouter_api_key, autocomplete: "off" %>
      <small>Get one at <a href="https://openrouter.ai/keys" target="_blank">openrouter.ai/keys</a>. Required — your key powers your projects.</small>
    </div>
  <% end %>

  <%= f.submit "Sign up" %>
<% end %>
```

(Tailwind / styling polish is out of scope for the plan; the template is functional.)

#### 7. Account-edit view (rotate OpenRouter key, change name/email/password)

Without this, a user whose key gets revoked at OpenRouter has no recourse short of `bin/rails console` on the host. The registrations controller already permits `profile_attributes` for `:account_update` (step 5). This step adds the matching view + a controller wrinkle for "leave key blank to keep current".

**File:** `app/views/devise/registrations/edit.html.erb` — generate via `bin/rails generate devise:views`, then edit:

```erb
<%= form_for(resource, as: resource_name, url: registration_path(resource_name), html: { method: :put }) do |f| %>
  <%= devise_error_messages! %>

  <div><%= f.label :email %><%= f.email_field :email, autocomplete: "email" %></div>

  <%= f.fields_for :profile do |pf| %>
    <div><%= pf.label :first_name %><%= pf.text_field :first_name %></div>
    <div><%= pf.label :last_name  %><%= pf.text_field :last_name %></div>
    <div>
      <%= pf.label :openrouter_api_key, "OpenRouter API key" %>
      <%= pf.password_field :openrouter_api_key, autocomplete: "off",
            placeholder: "(unchanged — leave blank to keep current key)" %>
      <small>Rotate at <a href="https://openrouter.ai/keys" target="_blank">openrouter.ai/keys</a>.</small>
    </div>
  <% end %>

  <h3>Change password (optional)</h3>
  <div><%= f.label :password, "New password" %><%= f.password_field :password, autocomplete: "new-password" %></div>
  <div><%= f.label :password_confirmation %><%= f.password_field :password_confirmation, autocomplete: "new-password" %></div>

  <h3>Confirm changes</h3>
  <div><%= f.label :current_password %><%= f.password_field :current_password, autocomplete: "current-password" %></div>

  <%= f.submit "Update" %>
<% end %>
```

**Controller wrinkle:** an empty `openrouter_api_key` field would overwrite the stored key with `""` and then fail the presence validation, which is a confusing error and (worse) leaves the user mid-broken if validation accidentally allows it. Strip the blank field before Devise sees it.

**File:** `app/controllers/users/registrations_controller.rb` — add:

```ruby
def update
  attrs = params.dig(:user, :profile_attributes)
  if attrs && attrs[:openrouter_api_key].blank?
    attrs.delete(:openrouter_api_key)
  end
  super
end
```

(Same logic could be done as `reject_if` on `accepts_nested_attributes_for`, but `reject_if` would also block legitimate updates where only the key changes; the controller-level strip is the targeted fix.)

**File:** Generator's main layout (or `home/index` for logged-in nav) — add a small link cluster, e.g.:

```erb
<% if user_signed_in? %>
  <%= link_to "Account", edit_user_registration_path %> ·
  <%= link_to "Sign out", destroy_user_session_path, data: { turbo_method: :delete } %>
<% end %>
```

(Exact placement is layout-dependent; the constraint is "must be reachable from /projects without typing a URL".)

### Success Criteria

#### Automated Verification:
- [x] `bin/rails db:migrate` applies cleanly
- [x] `bin/rails test` passes
- [x] Registration controller test asserts user + profile created with all five fields, fails when openrouter_api_key blank on signup
- [x] Login controller test asserts session establishment
- [x] `bin/rails routes | grep user` shows Devise routes registered
- [x] **User invariant test**: `User.create(email: "x@y.z", password: "password123")` (no profile_attributes, no built profile) → fails with `Profile can't be blank`. Confirms the `validates :profile, presence: true` invariant — no path can produce a profile-less user.
- [x] Registration controller `#update` test: POST with blank `openrouter_api_key` field + valid `current_password` + new `first_name` → profile keeps existing key, first_name updates, no validation error
- [x] Registration controller `#update` test: POST with NEW `openrouter_api_key` + valid `current_password` → profile.openrouter_api_key updates to new value (decrypted-readable check)

#### Manual Verification:
- [x] `bin/dev`, browse `/users/sign_up`, fill in all fields → land on `/` with a flash; `User.last.profile.first_name` matches form input; `User.last.profile.openrouter_api_key` is decrypted-readable.
- [x] Submit signup with blank `openrouter_api_key` → form re-renders with validation error.
- [x] Sign out, sign in with same credentials → succeed.
- [x] As signed-in user, click Account link → land on `/users/edit` with profile fields prefilled (key field blank).
- [x] Submit edit with new key + current_password → `User.last.profile.openrouter_api_key` reflects the new value.
- [x] Submit edit with blank key field + new first_name + current_password → key UNCHANGED, first_name updated.

**Note (mid-phase tweak):** plan originally required `current_password` for any account update. Reality: that blocked rotating the OpenRouter key. Followup commit overrides `update_resource` so `current_password` is only required when password or email actually change.

**Implementation Note**: After this phase passes automated checks, pause for manual confirmation before Phase 2.

---

## Phase 2: `user_id` FK on projects + ownership enforcement

### Commit
`phase 4 step 2: projects belong to user; ownership-gated mutations`

### Overview

Drop and recreate dev DB (per decision: no backfill, dev data is scratch). Add `user_id NOT NULL` FK on projects. `ProjectsController#new`/`#create` require login; `#create` sets `user_id` from `current_user`. `MessagesController#create`, `PreviewsController#create`/`#destroy` add `before_action :require_owner!`. `Project#show` stays accessible to anyone (the public face is the preview hostname, but the studio URL itself is currently not redirected — login + ownership *is* required for the studio per the decision; corrected here).

**Correction from earlier outline:** the studio at `/projects/:id` requires login + ownership. The PUBLIC URL is the preview hostname (`<id>.preview.hifumi.dev`), not `/projects/:id`.

### Changes Required

#### 1. Migration: drop dev DB, add `user_id` FK

```bash
bin/rails db:drop db:create db:migrate
```

Then generate:

```bash
bin/rails generate migration AddUserToProjects user:references
```

Edit migration to use NOT NULL:

```ruby
class AddUserToProjects < ActiveRecord::Migration[8.1]
  def change
    add_reference :projects, :user, null: false, foreign_key: true
  end
end
```

`bin/rails db:migrate`.

#### 2. Update `Project` model

**File:** `app/models/project.rb`

Add at top of class body (after `class Project < ApplicationRecord`):

```ruby
belongs_to :user
```

#### 3. Authorization concern

**File:** `app/controllers/concerns/project_owner_required.rb` (new)

```ruby
module ProjectOwnerRequired
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!
    before_action :load_project_and_authorize!
  end

  private

  def load_project_and_authorize!
    @project = Project.find(params[:project_id] || params[:id])
    redirect_to root_path, alert: "Not your project" unless @project.user_id == current_user&.id
  end
end
```

#### 4. `ProjectsController` updates

**File:** `app/controllers/projects_controller.rb`

```ruby
class ProjectsController < ApplicationController
  before_action :authenticate_user!, except: []   # all actions require login (no public studio)
  before_action :load_project_and_authorize!, only: [:show, :destroy]

  def new
    @project = Project.new
  end

  def create
    description = project_params[:description].to_s.strip

    if description.blank?
      @project = Project.new
      @error = "Please describe what you want to build."
      return render :new, status: :unprocessable_entity
    end

    project = current_user.projects.create!(name: description.truncate(60))
    chat = GeneratorAgent.create!(project: project)
    first_message = chat.messages.create!(role: :user, content: description)
    ChatRespondJob.perform_later(first_message.id)

    redirect_to project
  end

  def show
    @messages = @project.chat.messages.order(:created_at)
    @active_revisions = active_revisions_for(@project)
  end

  def destroy
    @project.destroy!
    redirect_to projects_path, notice: "Project deleted"
  end

  private

  def load_project_and_authorize!
    @project = Project.find(params[:id])
    unless @project.user_id == current_user.id
      redirect_to root_path, alert: "Not your project"
    end
  end

  def active_revisions_for(project)
    instruction = project.instructions
      .where.not(phase: %w[completed failed cancelled])
      .order(:created_at).last
    instruction&.revisions&.order(:position) || []
  end

  def project_params
    params.require(:project).permit(:description)
  end
end
```

#### 5. `MessagesController` and `PreviewsController` ownership guards

**File:** `app/controllers/messages_controller.rb`

Add at top:

```ruby
include ProjectOwnerRequired
```

**File:** `app/controllers/previews_controller.rb`

Add at top:

```ruby
include ProjectOwnerRequired
```

(The concern resolves `params[:project_id]` for the nested routes.)

#### 6. Routes — add `index` and `destroy`

**File:** `config/routes.rb`

```ruby
resources :projects, only: [:index, :new, :create, :show, :destroy] do
  resources :messages, only: [:create]
  resource  :preview,  only: [:create, :destroy]
end
```

(Phase 3 fills in `index` view + `HomeController` for root.)

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` passes
- [x] `ProjectsControllerTest` covers: anon visiting `new` → redirect to login; logged-in user creating project → `project.user == user`; logged-in user viewing other user's project → redirect with alert; logged-in owner viewing their project → 200.
- [x] `MessagesControllerTest` covers: anon → redirect; non-owner → redirect; owner → success.
- [x] `PreviewsControllerTest` covers same three branches for both `create` and `destroy`.

#### Manual Verification:
- [x] Sign up, create a project → succeed, project listed under that user.
- [x] Sign out, hit `/projects/<id>` → redirected to login.
- [x] Sign up as a second user, hit first user's project URL → redirected with "Not your project".
- [x] Sign back in as owner, hit `/projects/<id>` → see studio.

**Implementation Note**: Pause for manual confirmation before Phase 3.

---

## Phase 3: `ProjectsController#index` + root URL via `HomeController`

### Commit
`phase 4 step 3: projects index + welcome root for anonymous visitors`

### Overview

Add `ProjectsController#index` (logged-in user's projects, ordered by `created_at: :desc`, with state badge per project). Add `HomeController#index` for the root: redirects logged-in users to `/projects`, renders a one-screen welcome view with [Sign up] / [Log in] CTAs for anonymous visitors.

### Changes Required

#### 1. `ProjectsController#index`

**File:** `app/controllers/projects_controller.rb` — add:

```ruby
def index
  @projects = current_user.projects.order(created_at: :desc)
end
```

#### 2. Index view

**File:** `app/views/projects/index.html.erb` (new)

```erb
<h1>Your projects</h1>

<%= link_to "+ New project", new_project_path %>

<% if @projects.any? %>
  <ul>
    <% @projects.each do |project| %>
      <li>
        <%= link_to project.name, project %>
        <small>
          (<%= project.preview_state %>) — created <%= time_ago_in_words(project.created_at) %> ago
          <%= button_to "Delete", project, method: :delete, data: { confirm: "Delete \"#{project.name}\"?" } %>
        </small>
      </li>
    <% end %>
  </ul>
<% else %>
  <p>No projects yet. <%= link_to "Create your first one", new_project_path %>.</p>
<% end %>
```

#### 3. `HomeController`

**File:** `app/controllers/home_controller.rb` (new)

```ruby
class HomeController < ApplicationController
  def index
    redirect_to projects_path and return if user_signed_in?
    # else render the welcome view
  end
end
```

**File:** `app/views/home/index.html.erb` (new)

```erb
<h1>hifumi.dev</h1>
<p>Build Rails apps from a chat prompt. Bring your own OpenRouter key.</p>
<p>
  <%= link_to "Sign up", new_user_registration_path %>
  &nbsp;
  <%= link_to "Log in",  new_user_session_path %>
</p>
```

#### 4. Update root route

**File:** `config/routes.rb`

```ruby
root "home#index"
```

(Replaces `root "projects#new"`.)

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` passes
- [x] `HomeControllerTest`: anon → renders welcome; logged-in → redirects to `/projects`.
- [x] `ProjectsControllerTest#index`: anon → redirected; logged-in with 0 projects → empty-state copy present; logged-in with 2 projects → both names rendered, in `created_at desc` order.

#### Manual Verification:
- [x] Anon at `/` → see welcome with two CTAs; click Sign up → registration form.
- [x] Logged-in at `/` → redirected to `/projects`; create 2 projects → both listed newest-first.
- [x] Click Delete on a project → confirm dialog → project gone from list.

**Implementation Note**: Pause for manual confirmation before Phase 4.

---

## Phase 4: Per-user OpenRouter key everywhere (chat + roast + log scrubbing)

### Commit
`phase 4 step 4: per-user OpenRouter key in ChatRespondJob + ExecuteInstructionJob`

### Overview

Drop the global `OPENROUTER_API_KEY` ENV dependency from runtime LLM calls. Both `ChatRespondJob` (RubyLLM chat) and `ExecuteInstructionJob` (Roast subprocess) read the project owner's key from `project.user.profile.openrouter_api_key`. Add the key to Rails' log filter parameters so it never appears in logs/backtraces. Keep the ENV in `config/initializers/ruby_llm.rb` only as a *default* (so tests/CI can stub a sentinel key without per-test setup); production will not set it.

### Changes Required

#### 1. Update `ruby_llm.rb` initializer

**File:** `config/initializers/ruby_llm.rb`

```ruby
RubyLLM.configure do |config|
  # Optional default for dev/test; real per-call key is supplied per-request from
  # project.user.profile.openrouter_api_key in production. ENV unset in prod.
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  config.default_model = "anthropic/claude-haiku-4.5"
  config.use_new_acts_as = true
end
```

(No longer reads from credentials — credentials path was for a single-tenant default; per-user wins.)

#### 2. Update `ChatRespondJob` to use the per-user key

**File:** `app/jobs/chat_respond_job.rb`

RubyLLM's canonical pattern for a per-call API key (verified against `ruby-llm-v1` skill, `references/setup.md` § "Isolated contexts (multi-tenancy, per-request keys)" + `references/chat.md`): build a `RubyLLM.context { ... }` (which duplicates the global `Configuration` without mutating it) and pass it onto the chat instance via `chat.with_context(ctx)`. This is multi-tenant safe — concurrent jobs running with different keys cannot race on the global config.

```ruby
def perform(message_id)
  user_message = Message.find(message_id)
  chat = user_message.chat
  project = chat.project
  api_key = project.user.profile.openrouter_api_key
  raise "Project owner has no OpenRouter API key" if api_key.blank?

  ctx = RubyLLM.context do |c|
    c.openrouter_api_key = api_key
  end

  agent = GeneratorAgent.find(user_message.chat_id)
  agent.with_context(ctx).complete do |chunk|
    delta = chunk.content.to_s
    next if delta.empty?

    assistant = latest_streaming_assistant(chat)
    next if assistant.nil?

    assistant.update_columns(content: assistant.content.to_s + delta)
    broadcast_replace(project, assistant)
  end
rescue StandardError => e
  Rails.logger.error(e.full_message)
  target = latest_streaming_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
  target.update!(content: "Error: #{e.message}")
  broadcast_replace(project, target)
end
```

(`chat = user_message.chat` and `agent = GeneratorAgent.find(user_message.chat_id)` end up resolving to the same record — `GeneratorAgent` IS the chat model via `acts_as_chat`. Kept as two locals for symmetry with the existing job; may be collapsed at impl time if preferred.)

#### 3. Update `ExecuteInstructionJob` to inject per-user key into subprocess ENV

**File:** `app/jobs/execute_instruction_job.rb` — modify `execute_revision`:

```ruby
def execute_revision(revision, workspace)
  revision.update!(status: :generating, started_at: Time.current)
  ActiveSupport::Notifications.instrument("revision.started", revision_id: revision.id)

  api_key = revision.instruction.project.user.profile.openrouter_api_key
  raise "Project owner has no OpenRouter API key" if api_key.blank?

  env = {
    "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
    "RAILS_APP_GENERATOR_MODEL" => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet"),
    "OPENROUTER_API_KEY" => api_key
  }
  args = [
    Rails.root.join("bin/roast").to_s,                       # placeholder — Phase 7 swaps to bin/roast-openrouter / bin/roast-claudesubscription via env-branch helper
    Rails.root.join("lib/roast/revision_workflow.rb").to_s,
    "--",
    "revision_id=#{revision.id}",
    "revision_summary=#{revision.summary}",
    "revision_prompt=#{revision.prompt}"
  ]

  ok, exit_code, wall_seconds = run_roast_subprocess(env, args)

  metrics = {
    wall_seconds: wall_seconds,
    exit_code: exit_code,
    git_sha: git_head(workspace)
  }

  if ok
    revision.update!(status: :completed, finished_at: Time.current, git_sha: metrics[:git_sha], metrics: metrics)
    ActiveSupport::Notifications.instrument("revision.completed", revision_id: revision.id, git_sha: metrics[:git_sha])
  else
    revision.update!(status: :failed, finished_at: Time.current, metrics: metrics)
    ActiveSupport::Notifications.instrument("revision.failed", revision_id: revision.id, error: "exit #{exit_code}")
  end
end
```

(Phase 7 wraps the `bin/roast` line in an env-branched helper; for this phase the literal stays unchanged.)

#### 4. Log filter for the key (request params layer)

**File:** `config/initializers/filter_parameter_logging.rb`

```ruby
Rails.application.config.filter_parameters += [
  :passw, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn,
  :openrouter_api_key, :anthropic_auth_token, :anthropic_api_key
]
```

`filter_parameters` only filters values that flow through Rails' *request params* logger (i.e., the form post body that contains the key during signup/edit). It does **not** filter:
  - Exception messages / backtraces emitted via `Rails.logger.error(e.full_message)` (RubyLLM/Faraday error messages can include the request URL, headers, or response body — any of which can carry the API key).
  - Subprocess stdout/stderr from `bin/roast-openrouter` (Roast's own logs go to the parent process's stdout → captured by Kamal as the generator container's logs).

Step 5 below covers the runtime log path. The two layers are complementary; both are needed.

#### 5. Runtime log scrubbing (exception messages + subprocess output)

**File:** `app/lib/log_scrub.rb` (new)

```ruby
module LogScrub
  PATTERNS = [
    /sk-or-[A-Za-z0-9_-]{16,}/,    # OpenRouter
    /sk-ant-[A-Za-z0-9_-]{16,}/    # Anthropic (defensive — shouldn't appear in prod)
  ].freeze

  module_function

  def call(text)
    str = text.to_s
    PATTERNS.each { |p| str = str.gsub(p, "[FILTERED]") }
    str
  end
end
```

**File:** `app/jobs/chat_respond_job.rb` — replace the `rescue` block:

```ruby
rescue StandardError => e
  Rails.logger.error("[ChatRespondJob] message_id=#{message_id} #{e.class}: #{LogScrub.call(e.message)}")
  Rails.logger.error(LogScrub.call(e.backtrace.first(20).join("\n"))) if e.backtrace
  target = latest_streaming_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
  target.update!(content: "Error: #{LogScrub.call(e.message)}")
  broadcast_replace(project, target)
end
```

(The user-facing `Error: …` message is also scrubbed — the chat panel renders LLM error messages verbatim today, and a 401 response body from OpenRouter could echo the key right back to the browser.)

**File:** `app/jobs/execute_instruction_job.rb` — `run_roast_subprocess` switches from `system(env, *args)` (streams to inherited stdout) to `Open3.popen3` with line-by-line scrubbing, so the key cannot reach the generator's stdout uncensored:

```ruby
require "open3"

def run_roast_subprocess(env, args)
  started = Time.current
  exit_code = nil

  Open3.popen3(env, *args) do |stdin, stdout, stderr, wait_thread|
    stdin.close
    threads = [
      Thread.new { stdout.each_line { |line| Rails.logger.info(LogScrub.call(line.chomp)) } },
      Thread.new { stderr.each_line { |line| Rails.logger.error(LogScrub.call(line.chomp)) } }
    ]
    threads.each(&:join)
    exit_code = wait_thread.value.exitstatus
  end

  ok = exit_code == 0
  wall = (Time.current - started).round(2)
  [ok, exit_code, wall]
end
```

(Buffered-line behavior trades a tiny amount of streaming smoothness for the security guarantee; for ~5–15 min revisions, log latency is unchanged in practice. The previous behavior of sharing a TTY for interactive prompts was already gone in non-tty Solid Queue execution.)

#### 6. Verify `chat.with_context(ctx).complete` preserves `acts_as_chat` callbacks

The plan switches `agent.complete { … }` → `agent.with_context(ctx).complete { … }`. RubyLLM's `acts_as_chat` adds `on_new_message` / `on_end_message` callbacks to the chat instance — these create the assistant `Message` row, attach `ToolCall` records, and broadcast Turbo updates. If `with_context(ctx)` returns a wrapped/duped chat that *doesn't* carry those callbacks, the chat reply will silently never persist (the streaming `update_columns` only fires if `latest_streaming_assistant(chat)` finds a row that the callback was supposed to create).

**Verification before merging the phase:**

1. Add a Minitest case (in `ChatRespondJobTest` or a new `RubyLlmContextIsolationTest`) that:
   - Builds a `GeneratorAgent` with one user message persisted.
   - Stubs the OpenRouter HTTP layer (WebMock or `RubyLLM::Provider::Stub` — pick the one the existing test suite uses) to return a single short assistant reply.
   - Calls `agent.with_context(ctx).complete { }` with a non-nil `ctx`.
   - Asserts `chat.messages.where(role: :assistant).count == 1` AND that the assistant message has the stubbed content.

   If the assertion fails, **switch to per-job thread-local config mutation** instead — uglier but guaranteed to keep the original chat instance and its callbacks. Plan's fallback shape:

   ```ruby
   prev = RubyLLM.config.openrouter_api_key
   RubyLLM.config.openrouter_api_key = api_key
   begin
     agent.complete { |chunk| ... }
   ensure
     RubyLLM.config.openrouter_api_key = prev
   end
   ```

   Wrap with a per-process Mutex if Solid Queue may run multiple `ChatRespondJob`s concurrently in the same Puma process (`SOLID_QUEUE_IN_PUMA: true`). This is concurrency-unsafe by default — that's exactly *why* `with_context` is preferred — so use the fallback only if `with_context` proves broken.

2. Note the result in the commit message ("verified `with_context` preserves callbacks: yes" or "fell back to mutex-guarded mutation: …").

### Success Criteria

#### Automated Verification:
- [x] `bin/rails test` passes
- [x] `ChatRespondJobTest`: with a fixture user whose profile.openrouter_api_key = "sk-or-test...", asserts the RubyLLM call receives that key. Stub network calls via WebMock or RubyLLM's testing facilities.
- [x] `ChatRespondJobTest`: callback-preservation case (step 6 above) — `with_context(ctx).complete { }` still creates the assistant Message row.
- [x] `ExecuteInstructionJobTest`: stubs `run_roast_subprocess` and asserts it received `{"OPENROUTER_API_KEY" => "sk-or-test..."}` in the env hash.
- [x] Test asserts `Rails.application.config.filter_parameters` includes `:openrouter_api_key`.
- [x] `LogScrub` unit test: scrubs `sk-or-abc1234567890123` → `[FILTERED]`; passes through unrelated text unchanged.
- [x] `ChatRespondJob` rescue test: stub the LLM call to raise `StandardError.new("auth failed for sk-or-leaked123456789")`; assert that no `sk-or-*` substring appears in `Rails.logger`'s captured output AND that the broadcasted user-facing Message content also contains `[FILTERED]` not the raw key.

**Note (RubyLLM 1.14.1 caveat):** `acts_as_chat` (`use_new_acts_as = true`) does NOT delegate `with_context` from the AR record to the underlying `RubyLLM::Chat` (only `with_temperature` / `with_thinking` / `with_params` / `with_headers` / `with_schema` are delegated — verified in `chat_methods.rb:132-156`). So `app/models/chat.rb` patches it in, mirroring the same `to_llm.with_context(context); self` shape used by the other delegators. `with_context` on the underlying RubyLLM::Chat returns `self` and mutates in place, so `acts_as_chat` callbacks survive.

#### Manual Verification:
- [ ] Sign up, create a project, send an instruction → instruction completes (chat reply streams in, revision runs).
- [ ] Sign up a second user with a DIFFERENT (or invalid) OpenRouter key, create a project, send an instruction → that user's project hits an error from OpenRouter (visible in revision status: failed with API auth error). Confirms keys are per-user.
- [ ] Tail `log/development.log` during a generation, AND `log/production.log` after the Phase 11 deploy → confirm no `sk-or-...` key string appears anywhere (`grep -E 'sk-or-[A-Za-z0-9_-]{16,}' log/*.log` returns nothing).
- [ ] Provoke an OpenRouter 401 by deliberately corrupting a test user's saved key, send a chat message → the in-UI error bubble shows `[FILTERED]` not the raw key, and the log line shows `[FILTERED]` not the raw key.

**Implementation Note**: Pause for manual confirmation before Phase 5. This phase is the critical multi-tenancy data integrity AND key-leakage check.
