---
date: 2026-04-28
author: Paweł Strzałkowski (with Claude)
status: ready-for-implementation
phase: 4
scope: lean
predecessor_research: thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md
predecessor_plan: thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md
---

# Phase 4 — Production deploy on Hetzner with kamal-proxy + multi-tenancy

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

  has_one :profile, dependent: :destroy, inverse_of: :user
  accepts_nested_attributes_for :profile

  has_many :projects, dependent: :destroy   # FK lands in Phase 2; declared here for forward compatibility
end
```

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

#### 7. Add `Profile` to `current_user.profile` access guard

If `current_user.profile` is nil for any reason (legacy data, partial creation), defensively build it. We're nuking dev data in Phase 2 so this shouldn't happen, but for safety:

**File:** `app/models/user.rb` — add:

```ruby
def profile
  super || build_profile
end
```

#### 8. Account-edit view (rotate OpenRouter key, change name/email/password)

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
- [ ] `bin/rails db:migrate` applies cleanly
- [ ] `bin/rails test` passes
- [ ] Registration controller test asserts user + profile created with all five fields, fails when openrouter_api_key blank on signup
- [ ] Login controller test asserts session establishment
- [ ] `bin/rails routes | grep user` shows Devise routes registered
- [ ] Registration controller `#update` test: POST with blank `openrouter_api_key` field + valid `current_password` + new `first_name` → profile keeps existing key, first_name updates, no validation error
- [ ] Registration controller `#update` test: POST with NEW `openrouter_api_key` + valid `current_password` → profile.openrouter_api_key updates to new value (decrypted-readable check)

#### Manual Verification:
- [ ] `bin/dev`, browse `/users/sign_up`, fill in all fields → land on `/` with a flash; `User.last.profile.first_name` matches form input; `User.last.profile.openrouter_api_key` is decrypted-readable.
- [ ] Submit signup with blank `openrouter_api_key` → form re-renders with validation error.
- [ ] Sign out, sign in with same credentials → succeed.
- [ ] As signed-in user, click Account link → land on `/users/edit` with profile fields prefilled (key field blank).
- [ ] Submit edit with new key + current_password → `User.last.profile.openrouter_api_key` reflects the new value.
- [ ] Submit edit with blank key field + new first_name + current_password → key UNCHANGED, first_name updated.

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
- [ ] `bin/rails test` passes
- [ ] `ProjectsControllerTest` covers: anon visiting `new` → redirect to login; logged-in user creating project → `project.user == user`; logged-in user viewing other user's project → redirect with alert; logged-in owner viewing their project → 200.
- [ ] `MessagesControllerTest` covers: anon → redirect; non-owner → redirect; owner → success.
- [ ] `PreviewsControllerTest` covers same three branches for both `create` and `destroy`.

#### Manual Verification:
- [ ] Sign up, create a project → succeed, project listed under that user.
- [ ] Sign out, hit `/projects/<id>` → redirected to login.
- [ ] Sign up as a second user, hit first user's project URL → redirected with "Not your project".
- [ ] Sign back in as owner, hit `/projects/<id>` → see studio.

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
- [ ] `bin/rails test` passes
- [ ] `HomeControllerTest`: anon → renders welcome; logged-in → redirects to `/projects`.
- [ ] `ProjectsControllerTest#index`: anon → redirected; logged-in with 0 projects → empty-state copy present; logged-in with 2 projects → both names rendered, in `created_at desc` order.

#### Manual Verification:
- [ ] Anon at `/` → see welcome with two CTAs; click Sign up → registration form.
- [ ] Logged-in at `/` → redirected to `/projects`; create 2 projects → both listed newest-first.
- [ ] Click Delete on a project → confirm dialog → project gone from list.

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
    Rails.root.join("bin/roast").to_s,                       # placeholder — Phase 6 swaps to bin/roast-openrouter / bin/roast-claudesubscription via env-branch helper
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

(Phase 6 wraps the `bin/roast` line in an env-branched helper; for this phase the literal stays unchanged.)

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
- [ ] `bin/rails test` passes
- [ ] `ChatRespondJobTest`: with a fixture user whose profile.openrouter_api_key = "sk-or-test...", asserts the RubyLLM call receives that key. Stub network calls via WebMock or RubyLLM's testing facilities.
- [ ] `ChatRespondJobTest`: callback-preservation case (step 6 above) — `with_context(ctx).complete { }` still creates the assistant Message row.
- [ ] `ExecuteInstructionJobTest`: stubs `run_roast_subprocess` and asserts it received `{"OPENROUTER_API_KEY" => "sk-or-test..."}` in the env hash.
- [ ] Test asserts `Rails.application.config.filter_parameters` includes `:openrouter_api_key`.
- [ ] `LogScrub` unit test: scrubs `sk-or-abc1234567890123` → `[FILTERED]`; passes through unrelated text unchanged.
- [ ] `ChatRespondJob` rescue test: stub the LLM call to raise `StandardError.new("auth failed for sk-or-leaked123456789")`; assert that no `sk-or-*` substring appears in `Rails.logger`'s captured output AND that the broadcasted user-facing Message content also contains `[FILTERED]` not the raw key.

#### Manual Verification:
- [ ] Sign up, create a project, send an instruction → instruction completes (chat reply streams in, revision runs).
- [ ] Sign up a second user with a DIFFERENT (or invalid) OpenRouter key, create a project, send an instruction → that user's project hits an error from OpenRouter (visible in revision status: failed with API auth error). Confirms keys are per-user.
- [ ] Tail `log/development.log` during a generation, AND `log/production.log` after the Phase 11 deploy → confirm no `sk-or-...` key string appears anywhere (`grep -E 'sk-or-[A-Za-z0-9_-]{16,}' log/*.log` returns nothing).
- [ ] Provoke an OpenRouter 401 by deliberately corrupting a test user's saved key, send a chat message → the in-UI error bubble shows `[FILTERED]` not the raw key, and the log line shows `[FILTERED]` not the raw key.

**Implementation Note**: Pause for manual confirmation before Phase 5. This phase is the critical multi-tenancy data integrity AND key-leakage check.

---

## Phase 5: Remove the idle-preview reaper

### Commit
`phase 4 step 5: remove CleanupIdlePreviewsJob (lifecycle: owner-controlled stop only)`

### Overview

Per the lifecycle decision (Q7 option a), the public preview URL must remain reachable as long as the owner wants it up. The 30-min idle reaper conflicts with this. Remove the job class, the recurring schedule entry, and any test that references it. The owner's only control is the explicit Stop button; previews run indefinitely otherwise.

### Changes Required

#### 1. Delete the job class

```bash
git rm app/jobs/cleanup_idle_previews_job.rb
```

#### 2. Delete the recurring entry

**File:** `config/recurring.yml`

```yaml
# Recurring Solid Queue jobs. cleanup_idle_previews was removed in Phase 4 —
# previews run until the owner explicitly stops them.

production:
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
```

**Drop the `default: &default` anchor entirely** rather than leaving it pointing at an empty/comment-only mapping. A `&anchor` over a comment-only block is `null` in YAML, and `<<: *anchor` merging a `null` into another mapping errors in Psych — Solid Queue would fail to load recurring jobs at boot. If `development:` needs scheduled jobs in a future phase, define them inline alongside `production:` then.

#### 3. Delete or update related tests

```bash
git rm test/jobs/cleanup_idle_previews_job_test.rb   # if exists
```

Search for other references: `grep -r CleanupIdlePreviews test/` and remove.

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `grep -r CleanupIdlePreviews app/ config/ test/` returns nothing

#### Manual Verification:
- [ ] Start a preview, wait 35 minutes → preview still running.
- [ ] Click Stop → preview stops as before.

**Implementation Note**: Manual verification of the 35-minute wait can be skipped in practice; the absence of the reaper is sufficient verification once tests pass.

---

## Phase 6: `Preview::Config` wrapper + `preview_url` derivation

### Commit
`phase 4 step 6: Preview::Config wrapper; preview_url switches on PREVIEW_DOMAIN`

### Overview

ENV reading lives at the system boundary (initializer → `Rails.configuration.preview.*`); domain code reads only from the typed wrapper `Preview::Config`. `Project#preview_url` switches between the dev (`http://localhost:#{port}`) and prod (`https://#{id}.preview.#{domain}`) paths based on `Preview::Config.remote?`.

### Changes Required

#### 1. New initializer

**File:** `config/initializers/preview_config.rb` (new)

```ruby
Rails.application.config.preview = ActiveSupport::OrderedOptions.new
Rails.application.config.preview.domain = ENV["PREVIEW_DOMAIN"]   # e.g. "hifumi.dev" in prod; nil in dev
Rails.application.config.preview.port_offset = 3000               # dev: localhost:#{3000 + project.id}
```

#### 2. New wrapper

**File:** `app/lib/preview/config.rb` (new)

```ruby
module Preview
  module Config
    module_function

    def domain
      Rails.configuration.preview.domain
    end

    def remote?
      domain.present?
    end

    def port_offset
      Rails.configuration.preview.port_offset
    end
  end
end
```

#### 3. `Project#preview_url` reads from wrapper

**File:** `app/models/project.rb`

```ruby
def preview_url
  return nil unless preview_running?

  if Preview::Config.remote?
    "https://#{id}.preview.#{Preview::Config.domain}"
  else
    "http://localhost:#{preview_port}"
  end
end

def preview_port
  Preview::Config.port_offset + id
end
```

(Memory `feedback_no_logic_in_views.md` keeps URL construction in the model — it's domain, not view. Memory `feedback_derive_dont_store.md` keeps `preview_url` as a method.)

#### 4. Test fixtures: ensure no test sets ENV or relies on the old shape

Search `grep -r "preview_url\|PREVIEW_DOMAIN" test/` and update any tests that hard-code `localhost:` to use a `Preview::Config` stub when checking the prod branch.

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `Preview::Config` unit test: with `Rails.configuration.preview.domain = nil` → `remote? == false`; with `"hifumi.dev"` → `remote? == true && domain == "hifumi.dev"`.
- [ ] `Project#preview_url` test: stubbed `Preview::Config.remote?` true → returns `https://<id>.preview.hifumi.dev`; false → returns `http://localhost:<port>`.
- [ ] Grep proves no `ENV[` reading in `app/models/`, `app/jobs/`, `app/lib/preview/preview_manager.rb` for `PREVIEW_DOMAIN` (the wrapper is the only reader).

#### Manual Verification:
- [ ] In dev (no `PREVIEW_DOMAIN` set), start a preview → iframe / link target is `http://localhost:30XX`. Existing behavior unchanged.

---

## Phase 7: Roast wrapper rename + env-branched selection

### Commit
`phase 4 step 7: rename bin/roast wrappers; ExecuteInstructionJob picks per Rails.env`

### Overview

`bin/roast` becomes the raw Bundler binstub (for direct testing). `bin/roast-claudesubscription` is the renamed wrapper that does the frum + ANTHROPIC scrub for dev with Claude Code. `bin/roast-openrouter` stays as-is (it's already prod-safe — no frum block). `ExecuteInstructionJob` selects via a tiny helper based on `Rails.env.production?` / `ENV["FORCE_OPENROUTER"]`.

### Changes Required

#### 1. Rename current `bin/roast` to `bin/roast-claudesubscription`

```bash
git mv bin/roast bin/roast-claudesubscription
```

(Contents unchanged.)

#### 2. Generate the default Bundler binstub

```bash
bundle binstubs roast --force
```

This regenerates `bin/roast` as a stock binstub (essentially `exec bundle exec roast "$@"`). Verify by reading the generated file.

#### 3. Update `ExecuteInstructionJob`

**File:** `app/jobs/execute_instruction_job.rb`

Add a private helper:

```ruby
def roast_executable
  if Rails.env.production? || ENV["FORCE_OPENROUTER"].present?
    Rails.root.join("bin/roast-openrouter").to_s
  else
    Rails.root.join("bin/roast-claudesubscription").to_s
  end
end
```

Replace `Rails.root.join("bin/roast").to_s` in the `args` array with `roast_executable`.

#### 4. Update CLAUDE.md Roast runner convention block

**File:** `CLAUDE.md`

Replace the "Roast runner" bullet under Conventions:

```markdown
- **Roast runner**: `bin/roast-claudesubscription` is the dev default (uses Claude Code subscription — wrapper unsets `ANTHROPIC_*` ENV + pins PATH to `.ruby-version` via frum). `bin/roast-openrouter` is the per-token alternative used in production and when `FORCE_OPENROUTER=1` in dev. `bin/roast` (the bundler binstub) calls `bundle exec roast` raw, no env setup — for direct testing only. `ExecuteInstructionJob` picks `-openrouter` in production / when `FORCE_OPENROUTER=1`, else `-claudesubscription`.
```

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `ExecuteInstructionJobTest`: stub `Rails.env.production?` → asserts `roast_executable` ends in `bin/roast-openrouter`; non-prod with `FORCE_OPENROUTER` set → same; non-prod without → ends in `bin/roast-claudesubscription`.
- [ ] `bin/roast --help` (if Roast supports it) or `bin/roast --version` runs without error (proves binstub is functional).

#### Manual Verification:
- [ ] In dev, send an instruction → executes via `bin/roast-claudesubscription` (frum-pinned Ruby; Claude Code subscription).
- [ ] In dev with `FORCE_OPENROUTER=1 bin/dev`, send an instruction → executes via `bin/roast-openrouter` against your dev OpenRouter key.

---

## Phase 8: Generator Dockerfile + `deploy.yml` prod values

### Commit
`phase 4 step 8: production Dockerfile (docker CLI, USER root) + deploy.yml for hifumi.dev`

### Overview

Dockerfile additions: install `docker-ce-cli` so the generator container can talk to the host Docker daemon over the bind-mounted socket; flip `USER 1000:1000` to `USER root` (justified — bind-mounted socket is effective root anyway). `config/deploy.yml` is fully populated for production: server IP, image name, registry, proxy.host, env, volumes (workspace bind mount + Docker socket bind mount), accessories none, hooks dir.

### Changes Required

#### 1. `Dockerfile`

**File:** `Dockerfile`

Add `docker-ce-cli` to the base apt install:

```dockerfile
# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 ca-certificates gnupg lsb-release && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y docker-ce-cli && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
```

Remove the `groupadd / useradd / USER 1000:1000` block from the final stage:

```dockerfile
# Final stage for app image
FROM base

# Generator runs as root inside the container — bind-mounted Docker socket is
# effective root on the host anyway, and root simplifies the workspace
# permissions (UID alignment with host bind mount path).

# Copy built artifacts: gems, application
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
```

(Drop `--chown=rails:rails` from the COPYs.)

#### 2. `config/deploy.yml`

**File:** `config/deploy.yml`

Full rewrite (concise, no comments beyond intent):

```yaml
service: hifumi-generator
image: hifumi-generator

servers:
  web:
    - 77.42.95.154

proxy:
  ssl: true
  host: hifumi.dev

registry:
  server: localhost:5555

env:
  secret:
    - RAILS_MASTER_KEY
    - SMTP_PASSWORD              # Resend SMTP key today; provider-neutral name keeps swap trivial
  clear:
    SOLID_QUEUE_IN_PUMA: true
    PREVIEW_DOMAIN: hifumi.dev
    RAILS_APP_GENERATOR_WORKSPACE_ROOT: /var/lib/rails-app-generator/workspaces

volumes:
  - "rails_app_generator_storage:/rails/storage"
  - "/var/lib/rails-app-generator/workspaces:/var/lib/rails-app-generator/workspaces"
  - "/var/run/docker.sock:/var/run/docker.sock"

asset_path: /rails/public/assets

builder:
  arch: amd64

aliases:
  console: app exec --interactive --reuse "bin/rails console"
  shell:   app exec --interactive --reuse "bash"
  logs:    app logs -f
  dbc:     app exec --interactive --reuse "bin/rails dbconsole --include-password"
```

#### 3. `.kamal/secrets`

**File:** `.kamal/secrets`

```sh
# Secrets are loaded into ENV during `kamal deploy`. Don't commit values.
RAILS_MASTER_KEY=$(cat config/master.key)
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD       # local registry doesn't need it; placeholder
SMTP_PASSWORD=$SMTP_PASSWORD                            # Resend API key today; set via 1password / shell env when running kamal
```

(The deployer exports `SMTP_PASSWORD` (Resend's `re_...` key value) in their shell before `kamal deploy`. To switch SMTP providers later: change `address` / `user_name` in `config/environments/production.rb` and the value of `SMTP_PASSWORD` in the deploy shell. No env var rename needed.)

#### 4. Pre-create the workspace dir on the host

This is a one-shot manual step before first deploy (covered in the Phase 11 smoke):

```bash
ssh root@77.42.95.154 'mkdir -p /var/lib/rails-app-generator/workspaces && chmod 0755 /var/lib/rails-app-generator/workspaces'
```

(No chown needed since the container runs as root.)

### Success Criteria

#### Automated Verification:
- [ ] `kamal config` parses without error (`bundle exec kamal config`)
- [ ] `hadolint Dockerfile` reports no errors (warnings OK)
- [ ] `docker build -t hifumi-generator-test .` succeeds locally (just verifies the Dockerfile is syntactically valid; this is `--builder.arch amd64` so on Apple Silicon it'll cross-build via QEMU — slow but works)

#### Manual Verification:
- [ ] In a built image: `docker run --rm hifumi-generator-test docker --version` prints a docker CLI version (proves CLI installed).
- [ ] `bundle exec kamal config | grep image:` shows `hifumi-generator`.

**Note:** This phase doesn't deploy. Deploy happens in Phase 11. This phase only stages the config.

---

## Phase 9: `.kamal/hooks/pre-deploy` bootstrap script

### Commit
`phase 4 step 9: pre-deploy hook (network create, kamal-proxy attach, preview-base build)`

### Overview

A single idempotent shell script run on the host before each Kamal deploy. Three steps: ensure `--internal preview-internal` Docker network exists; ensure kamal-proxy container is attached to it; build/refresh the `preview-base:latest` image. All three are cheap no-ops when already done.

### Changes Required

#### 1. The hook

**File:** `.kamal/hooks/pre-deploy` (new, executable: `chmod +x`)

```bash
#!/usr/bin/env bash
# Phase 4 production bootstrap. Idempotent — safe to run on every deploy.
set -euo pipefail

# 1. Strict-egress preview network. --internal blocks outbound traffic from
#    containers attached only to this network.
if ! docker network inspect preview-internal >/dev/null 2>&1; then
  echo "[pre-deploy] Creating preview-internal network (--internal)"
  docker network create --internal preview-internal
fi

# 2. Attach kamal-proxy to preview-internal so it can route to preview
#    containers. kamal-proxy retains its kamal-network attachment for
#    egress (Let's Encrypt, etc).
if ! docker network inspect preview-internal -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qw kamal-proxy; then
  echo "[pre-deploy] Connecting kamal-proxy to preview-internal"
  docker network connect preview-internal kamal-proxy
fi

# 3. Build/refresh preview-base image. ~25s warm if Gemfile.lock unchanged
#    (cached layers); ~5min cold (first deploy, or when bundle invalidates).
echo "[pre-deploy] Building preview-base:latest"
RUBY_VERSION=$(sed 's/^ruby-//' .ruby-version)
docker build \
  -t preview-base:latest \
  --build-arg RUBY_VERSION="$RUBY_VERSION" \
  -f lib/preview/Dockerfile.base \
  lib/preview/

echo "[pre-deploy] Bootstrap complete"
```

#### 2. Document the hook in CLAUDE.md `Conventions` block

(Done in Phase 13 docs update. For this phase, just the script.)

### Success Criteria

#### Automated Verification:
- [ ] `shellcheck .kamal/hooks/pre-deploy` reports no errors
- [ ] Script is executable (`stat -c '%a' .kamal/hooks/pre-deploy` is `755` or similar)

#### Manual Verification (deferred to Phase 11 deploy):
- [ ] On first deploy: hook runs, all three steps execute, all output as expected, deploy continues.
- [ ] On second deploy: hook runs, all three steps are no-ops (networks/connections already in place; `docker build` cache hits all layers). Total hook runtime <5s.

---

## Phase 10: PreviewManager prod additions (kamal-proxy register/remove + `--internal` flip + reconciling orphan reset + CSP)

### Commit
`phase 4 step 10: PreviewManager registers preview routes with kamal-proxy in prod; reset_orphans reconciles instead of nukes; CSP frame-src for preview subdomain`

### Overview

Five responsibilities added to `Preview::PreviewManager` (and one CSP initializer change), the first three activated only when `Preview::Config.remote?`:

1. **Network creation** (`ensure_network!`) flips to `--internal` flag.
2. **Container start sequence** — after `docker run` succeeds and the healthcheck passes, run `docker inspect` to grab the container IP on `preview-internal`, then `docker exec kamal-proxy kamal-proxy deploy preview-#{id} --target #{ip}:3000 --host #{id}.preview.#{domain} --tls`.
3. **Container stop sequence** — before `docker stop/rm`, run `docker exec kamal-proxy kamal-proxy remove preview-#{id}`.
4. **`reset_orphans!` rewritten** to RECONCILE rather than nuke. Today's logic kills every `preview-*` container on every Rails boot — fine for single-tenant dev, catastrophic for multi-tenant prod where each `kamal deploy` would wipe out every user's running preview container. The new logic distinguishes three categories: live container + DB row (preserve), live container + no/stale DB row (kill — true orphan), DB row + no container (mark stopped). Same logic runs in dev, where it's strictly a behavior improvement (no impact unless a developer has multiple `Project` rows in flight).
5. **kamal-proxy route housekeeping** during `reset_orphans!` — for every preview container we kill (category B), also `kamal-proxy remove preview-N` to keep proxy state in sync. Live previews (category A) keep their proxy routes intact across the generator restart because routes live in kamal-proxy's process state, not the generator's.
6. **CSP `frame-src`** for the cross-origin iframe. Dev = same-origin (localhost:3000 → localhost:30XX same site, different port — fine without CSP). Prod = different origin (`hifumi.dev` → `<id>.preview.hifumi.dev`). The current CSP initializer is fully commented out, so the iframe works today, but enabling CSP is a one-line hardening win that costs nothing and we want it for the live deploy.

In dev (`!Preview::Config.remote?`) the kamal-proxy commands are skipped; the reconciling reset and the CSP both still apply (CSP picks the dev branch for `frame-src`).

### Changes Required

#### 1. `ensure_network!` — flip to `--internal` in prod

**File:** `lib/preview/preview_manager.rb` (around lines 77-83)

```ruby
def ensure_network!
  return if @runner.run("docker", "network", "inspect", NETWORK).success?

  args = ["docker", "network", "create"]
  args << "--internal" if Preview::Config.remote?
  args << NETWORK
  result = @runner.run(*args)
  raise "docker network create #{NETWORK} failed: #{result.stderr}" unless result.success?
end
```

(The dev path stays without `--internal` so port-publish continues to work locally.)

#### 2. Container IP discovery + kamal-proxy registration after healthcheck

**File:** `lib/preview/preview_manager.rb` — modify the `start` flow (around the `preview.ready` instrument):

```ruby
def start(project)
  ensure_network!
  ensure_image!(project)
  container_name = run_container(project)
  wait_healthy!(project)
  register_with_proxy!(project, container_name) if Preview::Config.remote?

  project.update!(preview_state: :running, preview_started_at: Time.current, preview_error: nil)
  ActiveSupport::Notifications.instrument("preview.ready", project_id: project.id, url: project.preview_url)
  broadcast(project)
rescue => e
  handle_failure(project, e)
end

private

def register_with_proxy!(project, container_name)
  ip = container_ip(container_name)
  raise "Could not resolve container IP for #{container_name}" if ip.blank?

  result = @runner.run(
    "docker", "exec", "kamal-proxy",
    "kamal-proxy", "deploy", "preview-#{project.id}",
    "--target", "#{ip}:3000",
    "--host", "#{project.id}.preview.#{Preview::Config.domain}",
    "--tls"
  )
  raise "kamal-proxy deploy failed: #{result.stderr}" unless result.success?
end

def container_ip(container_name)
  result = @runner.run(
    "docker", "inspect",
    "-f", "{{(index .NetworkSettings.Networks \"#{NETWORK}\").IPAddress}}",
    container_name
  )
  return nil unless result.success?
  result.stdout.strip.presence
end
```

#### 3. Deregister on stop

**File:** `lib/preview/preview_manager.rb` — modify `stop`:

```ruby
def stop(project)
  return unless project.preview_container_id.present?

  if Preview::Config.remote?
    @runner.run("docker", "exec", "kamal-proxy", "kamal-proxy", "remove", "preview-#{project.id}")
    # ignore errors — route may already be gone (e.g., kamal-proxy restarted, or never registered)
  end

  @runner.run("docker", "rm", "-f", project.preview_container_id)
  project.update!(preview_state: :stopped, preview_container_id: nil, preview_started_at: nil)
  broadcast(project)
end
```

#### 4. `reset_orphans!` rewritten as three-category reconciliation

**File:** `lib/preview/preview_manager.rb` — REPLACE the existing class method (currently at `lib/preview/preview_manager.rb:100-116`):

```ruby
# Boot-time reconciliation. The Rails process may have restarted (Kamal
# deploy, manual `kamal app boot`, host reboot, OOM kill) while user
# previews were running. We do NOT want to kill every preview-* container
# on the host — running previews are user-owned state and survive the
# generator's restart because containers are managed by the host Docker
# daemon, not the Rails process.
#
# Three categories:
#   A) container live AND DB row :running with matching container_id  → leave alone
#   B) container live but no DB row claims it (stale row was reset, or
#      container started by some out-of-band path)                    → kill,
#      and remove the kamal-proxy route if remote
#   C) DB row :starting/:running but no live container                → mark stopped
#
# Wrapped in rescue so a missing Docker (CI, fresh machine) does not
# crash boot for non-preview workflows.
def self.reset_orphans!(runner: SystemRunner.new)
  list = runner.run("docker", "ps", "--format", "{{.Names}}", capture: true)   # NOTE: no -a → only running
  live_names = list.ok ? list.stdout.split("\n").map(&:strip).reject(&:empty?) : []
  live_preview_names = live_names.select { |n| n.start_with?(PREVIEW_CONTAINER_PREFIX) }
  live_ids = live_preview_names
    .map { |n| n.sub(/^#{PREVIEW_CONTAINER_PREFIX}/, "").to_i }
    .reject(&:zero?)
    .to_set

  db_running = Project.where(preview_state: %i[starting running]).pluck(:id)
  db_running_ids = db_running.to_set

  # Category B: live container, no live DB row → orphan, kill it.
  orphan_ids = live_ids - db_running_ids
  orphan_ids.each do |id|
    name = "#{PREVIEW_CONTAINER_PREFIX}#{id}"
    runner.run("docker", "rm", "-f", name)
    if Preview::Config.remote?
      runner.run("docker", "exec", "kamal-proxy", "kamal-proxy", "remove", name)
    end
  end

  # Category C: DB row claims running but no live container → mark stopped.
  stale_ids = db_running_ids - live_ids
  Project.where(id: stale_ids.to_a).find_each do |project|
    project.update!(
      preview_state: :stopped,
      preview_container_id: nil,
      preview_started_at: nil,
      preview_error: "Container missing on boot — marked stopped"
    )
  end

  # Category A: live container AND live DB row → no action. The preview
  # keeps serving traffic; the kamal-proxy route persists in the proxy's
  # own state across the generator restart.

  # Belt-and-braces: stopped/exited preview-* containers are also reaped
  # so disk doesn't accumulate. They serve no traffic; safe to remove.
  stopped = runner.run("docker", "ps", "-a", "--filter", "status=exited", "--format", "{{.Names}}", capture: true)
  if stopped.ok
    stopped.stdout.split("\n").map(&:strip).each do |name|
      next unless name.start_with?(PREVIEW_CONTAINER_PREFIX)
      runner.run("docker", "rm", "-f", name)
    end
  end
rescue => e
  Rails.logger.error("[PreviewManager.reset_orphans!] #{e.class}: #{e.message}")
end
```

(The existing `PREVIEW_CONTAINER_PREFIX` private constant at line 97 stays. The `kamal-proxy list` enumeration that was in the previous draft is dropped — categories B+C give us the same end-state coverage with one fewer parsing dependency on kamal-proxy CLI output. If a kamal-proxy route exists for a project that's now gone, the next start will overwrite it; in the meantime it just returns 502 — same behavior as a stopped preview. Good enough for Lean Phase 4.)

**Test impact:** the existing `E2E_PREVIEW=1 test/integration/preview_lifecycle_test.rb` should still pass. The new reset is *less aggressive* than the old reset, and the test's invariant is "after stop, preview state is :stopped and no container exists" — both still hold, the new code just doesn't kill containers it shouldn't.

#### 5. Remove host port mapping in prod

**File:** `lib/preview/preview_manager.rb` — `run_container` (around lines 141-172):

```ruby
def run_container(project)
  args = [
    "docker", "run", "-d",
    "--name", "preview-#{project.id}",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--read-only",
    "--memory=#{MEMORY_LIMIT}",
    "--cpus=#{CPU_LIMIT}",
    "--pids-limit=#{PIDS_LIMIT}",
    "--network=#{NETWORK}",
    "-v", "#{project.workspace_path}/storage:/app/storage"
  ]

  unless Preview::Config.remote?
    args.push("-p", "#{project.preview_port}:3000")
  end

  args.push("preview-#{project.id}:latest")

  result = @runner.run(*args)
  raise "docker run failed: #{result.stderr}" unless result.success?

  project.update!(preview_container_id: result.stdout.strip)
  "preview-#{project.id}"
end
```

#### 6. Healthcheck adjustment

In prod the healthcheck cannot hit `localhost:#{preview_port}` (no port mapping). Either:

- **Option A:** healthcheck `docker exec preview-#{id} curl -fsS http://localhost:3000/up` (curl from inside container).
- **Option B:** healthcheck `docker exec kamal-proxy curl -fsS http://#{ip}:3000/up` (from kamal-proxy's network position).

**Choose A** — the preview container has `curl` (it's in the base image apt install). Modify `wait_healthy!`:

```ruby
def wait_healthy!(project)
  deadline = Time.current + HEALTH_TIMEOUT_SECONDS

  if Preview::Config.remote?
    cmd = ["docker", "exec", "preview-#{project.id}", "curl", "-fsS", "-o", "/dev/null", "-m", "2", "http://localhost:3000/up"]
  else
    cmd = ["curl", "-fsS", "-o", "/dev/null", "-m", "2", "http://localhost:#{project.preview_port}/up"]
  end

  loop do
    return if @runner.run(*cmd).success?
    raise "Preview did not become healthy in #{HEALTH_TIMEOUT_SECONDS}s" if Time.current > deadline
    sleep HEALTH_INTERVAL_SECONDS
  end
end
```

#### 7. Content-Security-Policy for the cross-origin iframe

**File:** `config/initializers/content_security_policy.rb` — replace the fully-commented file Rails ships with:

```ruby
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self, :https
    policy.style_src   :self, :https, :unsafe_inline   # Tailwind / inline styles in views
    policy.connect_src :self, :https, "wss:", "ws:"    # Action Cable WebSocket

    # Preview iframe is cross-origin in prod (hifumi.dev → <id>.preview.hifumi.dev),
    # same-site in dev (localhost:3000 → localhost:30XX). Read PREVIEW_DOMAIN
    # directly from ENV here rather than via Preview::Config — initializers load
    # alphabetically and content_security_policy.rb loads BEFORE preview_config.rb.
    # The block itself is evaluated lazily per-request, so by request time both
    # initializers have loaded; we still prefer ENV here to keep the CSP file
    # standalone-correct without an ordering footgun.
    if (preview_domain = ENV["PREVIEW_DOMAIN"]).present?
      policy.frame_src :self, "https://*.preview.#{preview_domain}"
    else
      policy.frame_src :self, "http://localhost:*"     # dev iframe at localhost:30XX
    end
  end

  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end
```

(`unsafe_inline` on `style_src` matches the de-facto state of Rails apps using inline `<style>` blocks or `style="..."` attributes; if the generator's views are nonce-clean this can be tightened later. Out of scope for the lean cut.)

If a CSP violation surfaces in the browser console during the Phase 11 smoke (e.g., a preview iframe blocked despite the `frame_src` allowance, or a stylesheet blocked by `style_src`), capture the violation report and tighten/loosen the policy in a follow-up; do not block the deploy on it — the policy is hardening, not load-bearing.

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `PreviewManagerTest`: with `Preview::Config.remote?` stubbed `true`, asserts `register_with_proxy!` runs after healthcheck; with `false`, asserts no kamal-proxy commands invoked. Use the existing `SystemRunner` injection seam.
- [ ] `PreviewManagerTest#stop`: with `remote?` stubbed `true`, asserts `kamal-proxy remove` invoked before `docker rm`.
- [ ] `PreviewManagerTest.reset_orphans!`:
  - **Category A** (live container + matching DB row): live container is NOT killed; DB row is NOT touched. ← critical regression guard for the "deploy doesn't nuke previews" property.
  - **Category B** (live container, no DB row): container is killed; with `remote?` stubbed true, `kamal-proxy remove preview-<id>` is invoked too.
  - **Category C** (DB row, no live container): row is updated to `:stopped` with the "Container missing on boot — marked stopped" error message.
  - **Stopped-container reap**: a stopped `preview-N` container with no DB row gets `docker rm -f`'d.
- [ ] CSP test: with `ENV["PREVIEW_DOMAIN"] = "hifumi.dev"`, `Rails.application.config.content_security_policy.directives["frame-src"]` contains `https://*.preview.hifumi.dev`. With `PREVIEW_DOMAIN` blank, contains `http://localhost:*`.
- [ ] Existing `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb` still passes in dev (no kamal-proxy on dev machine; `Preview::Config.remote?` is false → kamal-proxy code paths skipped).

#### Manual Verification (deferred to Phase 11 deploy):
- [ ] After deploy, start a preview. Inspect `docker exec kamal-proxy kamal-proxy list` → see `preview-<id>` route.
- [ ] Hit `https://<id>.preview.hifumi.dev` → see live app with valid HTTPS cert.
- [ ] Stop preview. `docker exec kamal-proxy kamal-proxy list` → route gone.
- [ ] Hit `https://<id>.preview.hifumi.dev` after stop → kamal-proxy returns its default no-route response (no branded offline page in Lean Phase 4 — see "What We're NOT Doing").
- [ ] `docker exec preview-<id> curl https://example.com` → fails (egress blocked by `--internal`).
- [ ] **`kamal app boot` (forces generator restart) while a preview is RUNNING → preview survives**: container is NOT killed, DB row stays `:running`, `kamal-proxy list` still shows the route, and a browser hitting `<id>.preview.hifumi.dev` still gets the live app uninterrupted. ← This is the explicit assertion that the orphan-reset rewrite works.
- [ ] Provoke an orphan: `docker run -d --name preview-99999 --network preview-internal nginx:alpine` (no DB row), then `kamal app restart` → `preview-99999` is gone after boot reset.
- [ ] Provoke a stale row: `bin/rails runner "Project.last.update_columns(preview_state: :running, preview_container_id: 'fake')"` then `kamal app restart` → that project's row is now `:stopped` with the boot-reset error message.
- [ ] In a logged-in browser session at `hifumi.dev/projects/:id`, open DevTools console → no CSP violation errors related to the iframe; iframe loads `<id>.preview.hifumi.dev` content.

---

## Phase 11: Resend SMTP + Devise mailer + initial deploy + smoke

### Commit
`phase 4 step 11: Resend SMTP wiring + Devise mailer for password reset`

(The deploy itself isn't a commit; the smoke check is verification work that happens after this commit lands.)

### Overview

Configure Action Mailer for Resend SMTP in production, point Devise at the right sender, then perform the first production deploy and end-to-end smoke.

### Changes Required

#### 1. Resend SMTP configuration

**File:** `config/environments/production.rb`

Replace the commented `smtp_settings` block with:

```ruby
# SMTP transport — currently bound to Resend, swappable to any SMTP-speaking
# provider (Postmark, SendGrid, SES, etc.) by changing host/username and the
# SMTP_PASSWORD env value. No provider-specific gem, no API client, no
# webhooks — Action Mailer's stock SMTP only, per "zero vendor lock-in".
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address:        "smtp.resend.com",   # provider host
  port:           587,
  user_name:      "resend",            # provider username (Resend uses literal "resend")
  password:       ENV.fetch("SMTP_PASSWORD"),
  authentication: :plain,
  enable_starttls_auto: true
}
config.action_mailer.default_url_options = { host: "hifumi.dev", protocol: "https" }
config.action_mailer.raise_delivery_errors = true
```

#### 2. Devise mailer sender

**File:** `config/initializers/devise.rb`

```ruby
config.mailer_sender = "noreply@hifumi.dev"
```

(May already be set from Phase 1 — verify.)

#### 3. Resend (sending domain provisioned 2026-04-28)

`hifumi.dev` is registered as a Resend sending domain and verified. Sender identity ready for `noreply@hifumi.dev` via SMTP. Only remaining operator action before first deploy: **generate a Resend API key and export it as `SMTP_PASSWORD`** in the shell where `kamal setup`/`kamal deploy` will be run (Resend dashboard → API Keys → Create; the `re_...` value is the SMTP password). The env var is named `SMTP_PASSWORD` (not `RESEND_API_KEY`) so swapping to Postmark/SendGrid/SES later is a values-only change — no var rename.

#### 4. DNS (live at GoDaddy, propagated 2026-04-28)

Authoritative state (queried against `ns07.domaincontrol.com`):

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| A | `@` | `77.42.95.154` | Generator at `hifumi.dev` |
| A | `*.preview` | `77.42.95.154` | Wildcard for every `<id>.preview.hifumi.dev` |
| CNAME | `www` | `hifumi.dev` | Apex alias |
| TXT | `@` | `v=spf1 include:dc-fd741b8612._spfm.send.hifumi.dev ~all` | Root SPF (Resend) |
| TXT | `send` | `v=spf1 include:dc-fd741b8612._spfm.send.hifumi.dev ~all` | Send-subdomain SPF |
| TXT | `dc-fd741b8612._spfm.send` | `v=spf1 include:amazonses.com ~all` | Resend tracking-subdomain SPF (chains to Amazon SES) |
| MX | `send` | `10 feedback-smtp.eu-west-1.amazonses.com.` | Bounce processing (Resend, EU region) |
| TXT | `resend._domainkey` | `p=MIGfMA0GCSqGSIb3DQEBAQU...` (RSA pubkey) | DKIM (Resend) |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;` | DMARC (GoDaddy default; relax to `p=none` if first sends quarantine) |

Resend uses a unique tracking subdomain (`dc-fd741b8612._spfm...`) so the apex SPF stays short and Resend is removable later by deleting their records — no surgery on root SPF needed.

Verification command (one-shot, hits authoritative GoDaddy NS to bypass resolver caches):

```bash
for q in "hifumi.dev A" "anything.preview.hifumi.dev A" "www.hifumi.dev CNAME" "hifumi.dev TXT" "send.hifumi.dev TXT" "send.hifumi.dev MX" "resend._domainkey.hifumi.dev TXT" "_dmarc.hifumi.dev TXT"; do
  echo "=== $q ==="; dig @ns07.domaincontrol.com $q +short
done
```

#### 5. First deploy

```bash
cd /Users/pawel/projects/rails-app-generator
export SMTP_PASSWORD="re_..."   # Resend API key today; same env var name regardless of future SMTP provider
bundle exec kamal setup    # first time only; subsequent: kamal deploy
```

Watch output:
- Pre-deploy hook fires (network create, kamal-proxy attach, preview-base build)
- Image builds locally, pushes to `localhost:5555` on the host
- Container starts, healthcheck (`/up`) passes
- kamal-proxy fetches LE cert for `hifumi.dev` on first request

#### 6. End-to-end smoke

Manual checklist (see Desired End State § Verification):

1. `curl -I https://hifumi.dev` → 200, valid cert.
2. Browse `https://hifumi.dev` (anonymous) → welcome page.
3. Sign up with real email + Resend-deliverable address → confirm landing on `/projects`.
4. Use the "forgot password" flow → confirm email arrives via Resend.
5. Create a project, send instruction → confirm chat reply streams.
6. Wait for instruction to complete → click Start preview → wait for `running` state.
7. Click iframe link → `https://<id>.preview.hifumi.dev` opens in new tab → see live app, valid cert.
8. From a private window, hit same URL → see live app (proves public).
9. From private window, hit `https://hifumi.dev/projects/<id>` → redirected to login (proves studio is owner-only).
10. As owner, click Stop → wait `:stopped` → hit preview URL → kamal-proxy default no-route response (no branded page in Lean Phase 4).
11. `ssh root@77.42.95.154 'docker exec preview-<id> curl https://example.com'` after starting fresh → fails (egress blocked).
12. `curl -I https://perfectpitch.world` → still 200 (other tenants unaffected).
13. **Preview-survives-deploy check**: with a preview running for some test project, run `bundle exec kamal deploy` from the generator dir → after deploy completes, the preview container is still listed in `docker ps` on the host with the same container id, the project's DB row stays `:running`, `kamal-proxy list` still shows the route, and a private-window request to `https://<id>.preview.hifumi.dev` returns the live app uninterrupted. (Validates the orphan-reset rewrite under real Kamal restart conditions.)
14. **Log-scrub spot check**: `ssh root@77.42.95.154 'docker logs hifumi-generator-web-1 2>&1 | grep -E "sk-or-[A-Za-z0-9_-]{16,}"'` → no matches. Same for `journalctl -u docker` and any Solid Queue worker output.

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `Devise::Mailer.reset_password_instructions` test renders without error in test env
- [ ] `bundle exec kamal config` lints clean

#### Manual Verification:
All 12 smoke checks above.

**Implementation Note**: This is the riskiest phase. If anything fails, debug live; do not proceed to docs phase until smoke is green.

---

## Phase 12: Phase 4 retrospective doc

### Commit
`phase 4 step 12: Phase 4 retro doc`

### Overview

Write `docs/03-plans/03-phase-4-production-deploy.md` capturing what happened, what surprised, what got deferred. Lightweight — 1-2 pages, mirroring the structure of `docs/03-plans/02-phase-3-preview-isolation.md`.

### Changes Required

**File:** `docs/03-plans/03-phase-4-production-deploy.md` (new)

Sections:
- Status (closed at production-deploy level)
- Decisions made (link back to this plan's Q&A)
- What worked
- What surprised (manual notes added during deploy)
- Deferred to Phase 5 (the B-tier list — per-container subnets, wake-on-request, publish/unpublish, gVisor, multi-host, monitoring, DNS-01 wildcard cert, key rotation strategy, branded offline page for stopped previews)

### Success Criteria

#### Automated Verification:
- [ ] File exists; markdown lints clean

#### Manual Verification:
- [ ] Reads coherently; future-you can pick up the Phase 5 list from it

---

## Phase 13: CLAUDE.md status update + tech-stack docs refresh

### Commit
`phase 4 step 13: CLAUDE.md status, tech-stack, vision endpoint shape`

### Overview

Update the canonical status line in `CLAUDE.md` (Phase 4 closed, Phase 5 candidates listed). Update `docs/02-architecture/03-tech-stack.md` to describe the production topology (Kamal + kamal-proxy + Resend + per-user OpenRouter). `docs/01-vision/02-user-journey.md:428` already names the Phase 4 endpoint shape — verify it's accurate, no edit needed if so.

### Changes Required

#### 1. `CLAUDE.md` status block

**File:** `CLAUDE.md`

Replace the Phase 3 / Phase 4 lines under `## Status` with:

```markdown
- **Phase 3** (preview isolation via Kamal + Docker): closed at the local-PoC level on 2026-04-27.
- **Phase 4** (production deploy on Hetzner with kamal-proxy + DNS + per-host TLS + strict --internal network + per-user OpenRouter BYOK + Devise multi-tenancy): **closed** on 2026-04-2X. Generator at https://hifumi.dev; previews at https://<id>.preview.hifumi.dev. Plan: `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md`. Retro: `docs/03-plans/03-phase-4-production-deploy.md`. **Phase 5** candidates: per-container network subnets, wake-on-request, explicit publish/unpublish, gVisor/Firecracker, multi-host LB, monitoring dashboards, DNS-01 wildcard cert, branded offline page for stopped previews (kamal-proxy v0.9 wildcard limitation), key rotation, fork-this-project, model-selection UI, **Docker socket-proxy in front of `/var/run/docker.sock`** (mitigates the `USER root` + bound socket exposure today; an RCE in the generator currently grants full host root via the daemon).
```

#### 2. `docs/02-architecture/03-tech-stack.md` refresh

Add a "Production deployment" subsection describing the Hetzner host, kamal-proxy as router (already present at line 191 mention), Resend as transactional mail, and the per-user BYOK model.

#### 3. Update Convention block in `CLAUDE.md`

Update the "Preview infrastructure" line:

```markdown
- **Preview infrastructure**: `lib/preview/preview_manager.rb` drives Docker. In production, `Preview::Config.remote?` switches the network to `--internal` and adds kamal-proxy registration on start (`docker exec kamal-proxy kamal-proxy deploy/remove`). Pre-deploy hook (`.kamal/hooks/pre-deploy`) bootstraps the network, attaches kamal-proxy to `preview-internal`, and builds `preview-base:latest`. Read ENV only in `config/initializers/preview_config.rb` → `Preview::Config` wrapper exposes typed accessors.
```

### Success Criteria

#### Automated Verification:
- [ ] `markdownlint CLAUDE.md docs/` reports no errors

#### Manual Verification:
- [ ] CLAUDE.md status block reads accurately
- [ ] `git log --oneline | head -20` shows the 14 phase commits with sane messages

---

## Testing Strategy

### Unit Tests (per phase)
- `User`, `Profile` model tests — encryption round-trip, validation presence
- `Preview::Config` wrapper — branch on `domain` presence
- `Project#preview_url` — both branches stubbed via `Preview::Config`
- `PreviewManager` — kamal-proxy commands invoked / skipped per `Preview::Config.remote?`
- `ExecuteInstructionJob#roast_executable` — env-branch helper picks correct script

### Integration Tests
- `Devise::RegistrationsControllerTest` — full signup form roundtrip, including nested Profile params
- `ProjectsControllerTest` — auth gate, ownership enforcement, index ordering, destroy
- `MessagesControllerTest`, `PreviewsControllerTest` — non-owner returns alert
- Existing `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb` — must continue to pass in dev (kamal-proxy code paths skipped via `Preview::Config.remote?` false)

### Manual Smoke (Phase 11)
The 12-step end-to-end checklist above.

## Performance Considerations

- **Pre-deploy hook**: ~25s warm (preview-base layer cache hits when Gemfile.lock unchanged); ~5min cold on first deploy.
- **Kamal deploy**: image build + push to localhost:5555 + boot ~3-5min total. Acceptable for a single-developer cadence.
- **Per-preview Let's Encrypt cert fetch**: 1-3s on first request to a preview hostname. Subsequent requests hit cached cert.
- **kamal-proxy registration latency**: `docker exec kamal-proxy kamal-proxy deploy ...` is sub-second.
- **Preview cold start**: ~30-90s (docker build + bundle + healthcheck loop) — unchanged from Phase 3.

## Migration Notes

- **Dev DB**: nuked at Phase 2 (`db:drop db:create db:migrate`). No backfill, no seed user.
- **Prod DB**: fresh, no migration concern. First deploy creates the schema.
- **Preview-base image**: built by pre-deploy hook on first deploy. No manual seeding required.
- **kamal-proxy state**: existing routes for `perfectpitch.world`, `touchtype.<...>`, `blind_cv_generator.<...>` are untouched. New route for `hifumi.dev` adds via Kamal's normal flow; preview routes register dynamically per-preview.

## References

- Original research: `thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md`
- Predecessor plan: `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md`
- Phase 3 analysis (architecture diagram, kamal-proxy contracts): `docs/03-plans/02-phase-3-preview-isolation.md`
- Vision endpoint shape: `docs/01-vision/02-user-journey.md:428`
- W3 workflow contract: `docs/02-architecture/01-workflows-and-decisions.md:138-154`
- Pre-existing kamal-proxy on host: `docker ps` confirmed `basecamp/kamal-proxy:v0.9.0` on 80/443 routing 3 tenants
- RubyLLM gem (per-instance api_key): verify exact API at impl time per `ruby-llm-v1` skill
- Devise nested attributes pattern: standard Rails — `accepts_nested_attributes_for` + custom RegistrationsController
- Memories applied: `feedback_state_by_absence`, `feedback_derive_dont_store`, `feedback_no_logic_in_views`, `feedback_no_service_objects`, `project_dev_cable_solid`, `project_ruby_llm_*`, `project_form_replace_over_redirect`
