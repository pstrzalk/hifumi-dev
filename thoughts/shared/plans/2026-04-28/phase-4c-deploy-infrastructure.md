---
date: 2026-04-28
author: Paweł Strzałkowski (with Claude)
status: ready-for-implementation
phase: 4
part: c
scope: lean
predecessor_research: thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md
predecessor_plan: thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md
---

# Phase 4 — Production deploy on Hetzner with kamal-proxy + multi-tenancy
## Part C: Production Infrastructure (Phases 8–10)

> **Plan split into 4 parts (header duplicated in each):**
> - A: Phases 1–4 — auth + ownership + per-user OpenRouter key (`phase-4a-auth-and-ownership.md`)
> - B: Phases 5–7 — preview lifecycle refactors (`phase-4b-preview-refactors.md`)
> - **C** (this file): Phases 8–10 — Dockerfile + deploy.yml, pre-deploy hook, PreviewManager prod additions
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
- [x] `kamal config` parses without error (`bundle exec kamal config`)
- [ ] `hadolint Dockerfile` reports no errors (warnings OK) — *skipped: hadolint not installed; substituted `docker buildx build --check .` which reports "no warnings found".*
- [ ] `docker build -t hifumi-generator-test .` succeeds locally (just verifies the Dockerfile is syntactically valid; this is `--builder.arch amd64` so on Apple Silicon it'll cross-build via QEMU — slow but works) — *deferred to Phase 11 first deploy; `docker buildx build --check .` already validates syntax without the full QEMU build.*

#### Manual Verification:
- [ ] In a built image: `docker run --rm hifumi-generator-test docker --version` prints a docker CLI version (proves CLI installed).
- [ ] `bundle exec kamal config | grep image:` shows `hifumi-generator` — *self-verified during implementation; `:absolute_image: localhost:5555/hifumi-generator:...` returned. Awaiting your confirmation.*

**Note:** This phase doesn't deploy. Deploy happens in Phase 11. This phase only stages the config.

---

## Phase 9: `.kamal/hooks/pre-deploy` bootstrap script

### Commit
`phase 4 step 9: pre-deploy hook (network create, kamal-proxy attach, preview-base build)`

### Overview

A single idempotent shell script that bootstraps Hetzner state before each Kamal deploy. Three steps: ensure `--internal preview-internal` Docker network exists on the host; ensure kamal-proxy container is attached to it; build/refresh `preview-base:latest` on the host. All three are cheap no-ops when already done.

**Critical execution-context note.** Kamal pre-deploy hooks run **locally** on the deploying machine (verified: `kamal-2.11.0/lib/kamal/cli/base.rb:158` wraps hook execution in SSHKit's `run_locally do execute ... end` — no DOCKER_HOST rewrite, no SSH wrapping). Naive `docker network create ...` / `docker build ...` lines in the hook would target the developer's local Docker engine, not Hetzner. The script below explicitly SSHes into `root@77.42.95.154` for every command that needs to affect host state, and rsyncs the `lib/preview/` build context for the image build.

### Changes Required

#### 1. The hook

**File:** `.kamal/hooks/pre-deploy` (new, executable: `chmod +x`)

```bash
#!/usr/bin/env bash
# Phase 4 production bootstrap. Idempotent — safe to run on every deploy.
#
# Kamal hooks run LOCALLY (kamal-2.11.0/lib/kamal/cli/base.rb:158 → SSHKit
# `run_locally`), so every host-state mutation here is wrapped in `ssh`.
# Building preview-base needs the lib/preview/ directory on the host, so we
# rsync it into a scratch path first.
set -euo pipefail

HOST="${KAMAL_DEPLOY_HOST:-root@77.42.95.154}"
RUBY_VERSION=$(sed 's/^ruby-//' .ruby-version)

# 1+2. Ensure --internal preview-internal network on host; ensure kamal-proxy
#      is attached to it. Both idempotent. --internal blocks outbound traffic
#      from containers attached only to this network. kamal-proxy retains its
#      kamal-network attachment for egress (LE etc).
ssh "$HOST" 'set -e
  if ! docker network inspect preview-internal >/dev/null 2>&1; then
    echo "[pre-deploy] Creating preview-internal network (--internal) on host"
    docker network create --internal preview-internal
  fi
  if ! docker network inspect preview-internal \
        -f "{{range .Containers}}{{.Name}} {{end}}" \
       | grep -qw kamal-proxy; then
    echo "[pre-deploy] Connecting kamal-proxy to preview-internal on host"
    docker network connect preview-internal kamal-proxy
  fi
'

# 3. Build preview-base:latest on the host. ~25s warm (layer cache) when
#    Gemfile.lock unchanged; ~5min cold (first deploy, or bundle invalidation).
echo "[pre-deploy] Syncing lib/preview/ to host build context"
ssh "$HOST" 'mkdir -p /var/lib/rails-app-generator/preview-base-context'
rsync -az --delete \
  lib/preview/ \
  "$HOST:/var/lib/rails-app-generator/preview-base-context/"

echo "[pre-deploy] Building preview-base:latest on host"
ssh "$HOST" "docker build \
  -t preview-base:latest \
  --build-arg RUBY_VERSION='$RUBY_VERSION' \
  -f /var/lib/rails-app-generator/preview-base-context/Dockerfile.base \
  /var/lib/rails-app-generator/preview-base-context"

echo "[pre-deploy] Bootstrap complete"
```

**Prereq for the hook to work**: SSH key auth to `root@77.42.95.154` already configured (it is — Kamal itself relies on this). `rsync` available on both ends (standard on macOS + Debian). No other ambient state needed.

#### 2. Document the hook in CLAUDE.md `Conventions` block

(Done in Phase 13 docs update. For this phase, just the script.)

### Success Criteria

#### Automated Verification:
- [ ] `shellcheck .kamal/hooks/pre-deploy` reports no errors
- [ ] Script is executable (`stat -c '%a' .kamal/hooks/pre-deploy` is `755` or similar)
- [ ] Hook is a no-op on dry-run (`bundle exec kamal config` does NOT invoke the hook — only `deploy`/`redeploy`/`rollback` do, per `kamal-2.11.0/lib/kamal/cli/main.rb:34,70,93`)

#### Manual Verification (deferred to Phase 11 deploy):
- [ ] On first deploy: hook runs locally, SSHes into Hetzner, all three steps complete, deploy continues. Verify on host: `ssh root@77.42.95.154 'docker network inspect preview-internal | grep -E "Internal|Containers" -A2'` shows `"Internal": true` AND `kamal-proxy` listed under Containers; `ssh root@77.42.95.154 'docker images preview-base:latest'` shows the image.
- [ ] On second deploy: hook runs, network/connect steps are no-ops (idempotent grep guards short-circuit); `docker build` on host hits all layers from cache when Gemfile.lock unchanged. Total hook runtime <30s warm (rsync + cached build); local-side overhead is the rsync round-trip.
- [ ] Negative check (defends against the "runs locally" footgun): `docker network inspect preview-internal` on the **developer's machine** returns no such network — proves the hook didn't accidentally mutate local Docker state.

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

Preserve the existing class+instance shim pattern (line 83 instance method delegates to class method). The class method retains its `runner:` keyword for tests / boot-time injection.

```ruby
def self.ensure_network!(runner: SystemRunner.new)
  result = runner.run("docker", "network", "inspect", NETWORK, capture: true)
  return if result.ok

  args = ["docker", "network", "create"]
  args << "--internal" if Preview::Config.remote?
  args << NETWORK
  result = runner.run(*args, capture: true)
  raise "docker network create #{NETWORK} failed: #{result.stderr}" unless result.ok
end

def ensure_network! = self.class.ensure_network!(runner: @runner)
```

(The dev path stays without `--internal` so port-publish continues to work locally. `capture: true` matches the existing call at preview_manager.rb:78 — it keeps `docker network inspect`'s JSON output off the parent process's stdout, and on creation failure populates `result.stderr` for the raise message. The Result struct is `Struct.new(:ok, :stdout, :stderr, :exit_code, ...)` — `.ok`, not `.success?`.)

#### 2. Container IP discovery + kamal-proxy registration after healthcheck

**File:** `lib/preview/preview_manager.rb` — modify the existing `start` (line 29) and `run_container` (line 141), and add two new private helpers. Two surgical changes to `start`: insert the `register_with_proxy!` call between `health_check!` and the `:running` update, nothing else.

The `start` body is otherwise unchanged from existing — same `stop(project) if project.preview_container_id.present?` guard at the top, same early `:starting` state transition + broadcast (so the UI shows "Starting…" during the 30-90s build/run/healthcheck window), same `build_image` and `health_check!` method names.

```ruby
def start(project)
  stop(project) if project.preview_container_id.present?

  ensure_network!

  project.update!(
    preview_state: :starting,
    preview_started_at: Time.current,
    preview_error: nil
  )
  broadcast(project)

  tag = build_image(project)
  container_id = run_container(project, tag)
  project.update!(preview_container_id: container_id)

  health_check!(project)
  register_with_proxy!(project) if Preview::Config.remote?

  project.update!(preview_state: :running)
  ActiveSupport::Notifications.instrument(
    "preview.ready",
    project_id: project.id, url: project.preview_url
  )
  broadcast(project)
rescue => e
  handle_failure(project, e)
end

private

def register_with_proxy!(project)
  container_name = "preview-#{project.id}"
  ip = container_ip(container_name)
  raise "Could not resolve container IP for #{container_name}" if ip.blank?

  result = @runner.run(
    "docker", "exec", "kamal-proxy",
    "kamal-proxy", "deploy", "preview-#{project.id}",
    "--target", "#{ip}:3000",
    "--host", "#{project.id}.preview.#{Preview::Config.domain}",
    "--tls",
    capture: true
  )
  raise "kamal-proxy deploy failed: #{result.stderr}" unless result.ok
end

def container_ip(container_name)
  result = @runner.run(
    "docker", "inspect",
    "-f", "{{(index .NetworkSettings.Networks \"#{NETWORK}\").IPAddress}}",
    container_name,
    capture: true
  )
  return nil unless result.ok
  result.stdout.strip.presence
end
```

(`capture: true` is required on `container_ip` — without it `SystemRunner` uses `system(...)` and `result.stdout` is empty, so the IP can never be resolved and `register_with_proxy!` raises every time. `capture: true` on `register_with_proxy!` is for the error-path stderr so the raise message names what kamal-proxy actually rejected. Result struct uses `.ok`, not `.success?`.)

#### 3. Deregister on stop

**File:** `lib/preview/preview_manager.rb` — modify the existing `stop` (line 57). Surgical change: add the kamal-proxy remove call before the `docker rm` block, gated on `Preview::Config.remote?`. Keep the existing `image rm`, the `preview_error: nil` reset, and the always-run state update (so calling `stop` on a `:failed` project still resets state cleanly).

```ruby
def stop(project)
  cid = project.preview_container_id

  if Preview::Config.remote? && cid.present?
    # Ignore errors — route may already be gone (kamal-proxy restarted, never
    # registered, or stop called twice). Capture stderr only for the log.
    @runner.run(
      "docker", "exec", "kamal-proxy",
      "kamal-proxy", "remove", "preview-#{project.id}",
      capture: true
    )
  end

  if cid.present?
    @runner.run("docker", "rm", "-f", cid)
    @runner.run("docker", "image", "rm", "-f", project_tag(project))
  end

  project.update!(
    preview_state: :stopped,
    preview_container_id: nil,
    preview_started_at: nil,
    preview_error: nil
  )
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

**File:** `lib/preview/preview_manager.rb` — modify the existing `run_container(project, tag)` (line 141). Keep the existing `(project, tag)` signature and the existing return contract (returns `result.stdout.strip` — the container ID — for the caller to assign to `preview_container_id`). The only structural change is gating the host port-publish on `!Preview::Config.remote?`. The existing tmpfs / read-only / cap-drop / pids-limit / RAILS_LOG_TO_STDOUT / storage mount lines all stay.

```ruby
def run_container(project, tag)
  args = [
    "docker", "run", "-d",
    "--name", "preview-#{project.id}",
    "--memory=#{MEMORY_LIMIT}",
    "--memory-swap=#{MEMORY_LIMIT}",
    "--cpus=#{CPU_LIMIT}",
    "--pids-limit=#{PIDS_LIMIT}",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--network=#{NETWORK}",
    "--read-only",
    "--tmpfs", "/tmp:size=64m",
    "--tmpfs", "/app/tmp:size=64m",
    "--tmpfs", "/app/log:size=16m"
  ]

  unless Preview::Config.remote?
    args.push("-p", "#{project.preview_port}:3000")
  end

  args.push(
    "-v", "#{File.join(project.workspace_path, 'storage')}:/app/storage",
    "-e", "RAILS_LOG_TO_STDOUT=1",
    tag
  )

  result = @runner.run(*args, capture: true)
  raise RunError, result.stderr unless result.ok
  result.stdout.strip
end
```

(`capture: true` is required — without it `result.stdout` is empty, so `start` would assign an empty string to `preview_container_id` and subsequent `docker rm -f ""` calls during `stop` fail silently, leaving the container orphaned. Result struct uses `.ok`, not `.success?`. `RunError` is the existing exception class at preview_manager.rb:212.)

#### 6. Healthcheck adjustment

In prod the healthcheck cannot hit `localhost:#{preview_port}` (no port mapping). Either:

- **Option A:** healthcheck `docker exec preview-#{id} curl -fsS http://localhost:3000/up` (curl from inside container).
- **Option B:** healthcheck `docker exec kamal-proxy curl -fsS http://#{ip}:3000/up` (from kamal-proxy's network position).

**Choose A** — the preview container has `curl` (it's in the base image apt install). Modify the existing `health_check!` / `curl_ok?` pair (preview_manager.rb:174-187) — keep the existing method names, branch the URL+command on `Preview::Config.remote?`:

```ruby
def health_check!(project)
  deadline = Time.current + @health_timeout
  loop do
    return if curl_ok?(project)
    raise HealthcheckTimeout, "no /up after #{@health_timeout}s" if Time.current > deadline
    sleep @health_interval
  end
end

def curl_ok?(project)
  cmd =
    if Preview::Config.remote?
      ["docker", "exec", "preview-#{project.id}",
       "curl", "-fsS", "-o", "/dev/null", "-m", "2", "http://localhost:3000/up"]
    else
      ["curl", "-fsS", "-o", "/dev/null", "-m", "2",
       "http://localhost:#{project.preview_port}/up"]
    end

  @runner.run(*cmd, capture: true).ok
end
```

(`capture: true` matches the existing call at preview_manager.rb:185 and keeps the per-poll curl/docker-exec output off the parent's stdout. `HealthcheckTimeout` is the existing exception class at preview_manager.rb:213. Result struct uses `.ok`, not `.success?`. The `curl_ok?` signature changes from `(url)` to `(project)` — the existing single caller is `health_check!` itself, so no external breakage.)

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
