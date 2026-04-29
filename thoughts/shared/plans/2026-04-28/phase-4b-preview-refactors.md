---
date: 2026-04-28
author: Paweł Strzałkowski (with Claude)
status: ready-for-implementation
phase: 4
part: b
scope: lean
predecessor_research: thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md
predecessor_plan: thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md
---

# Phase 4 — Production deploy on Hetzner with kamal-proxy + multi-tenancy
## Part B: Preview Lifecycle Refactors (Phases 5–7)

> **Plan split into 4 parts (header duplicated in each):**
> - A: Phases 1–4 — auth + ownership + per-user OpenRouter key (`phase-4a-auth-and-ownership.md`)
> - **B** (this file): Phases 5–7 — drop reaper, `Preview::Config` wrapper, Roast wrapper rename
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
- [x] `bin/rails test` passes
- [x] `grep -r CleanupIdlePreviews app/ config/ test/` returns nothing

#### Manual Verification:
- [x] Start a preview, wait 35 minutes → preview still running.
- [x] Click Stop → preview stops as before.

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
- [x] `bin/rails test` passes
- [x] `Preview::Config` unit test: with `Rails.configuration.preview.domain = nil` → `remote? == false`; with `"hifumi.dev"` → `remote? == true && domain == "hifumi.dev"`.
- [x] `Project#preview_url` test: stubbed `Preview::Config.remote?` true → returns `https://<id>.preview.hifumi.dev`; false → returns `http://localhost:<port>`.
- [x] Grep proves no `ENV[` reading in `app/models/`, `app/jobs/`, `app/lib/preview/preview_manager.rb` for `PREVIEW_DOMAIN` (the wrapper is the only reader).

#### Manual Verification:
- [x] In dev (no `PREVIEW_DOMAIN` set), start a preview → iframe / link target is `http://localhost:30XX`. Existing behavior unchanged.

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
- [x] `bin/rails test` passes
- [x] `ExecuteInstructionJobTest`: stub `Rails.env.production?` → asserts `roast_executable` ends in `bin/roast-openrouter`; non-prod with `FORCE_OPENROUTER` set → same; non-prod without → ends in `bin/roast-claudesubscription`.
- [x] `bin/roast --help` (if Roast supports it) or `bin/roast --version` runs without error (proves binstub is functional).

#### Manual Verification:
- [x] In dev, send an instruction → executes via `bin/roast-claudesubscription` (frum-pinned Ruby; Claude Code subscription).
- [x] In dev with `FORCE_OPENROUTER=1 bin/dev`, send an instruction → executes via `bin/roast-openrouter` against your dev OpenRouter key.
