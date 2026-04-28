---
date: 2026-04-27T16:48:36+02:00
researcher: Paweł Strzałkowski
git_commit: b91e34ab1fbcb1234d125ec8463bcd9b3bad23b1
branch: main
repository: rails-app-generator
topic: "Knowledge for Phase 4 (production deploy on Hetzner/DO with kamal-proxy + DNS + wildcard cert + strict --internal network)"
tags: [research, codebase, phase-4, preview, kamal, kamal-proxy, docker, deployment, isolation]
status: complete
last_updated: 2026-04-27
last_updated_by: Paweł Strzałkowski
---

# Research: Knowledge for Phase 4 (production deploy + kamal-proxy + DNS + wildcard cert + strict `--internal` network)

**Date**: 2026-04-27 16:48 +02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: b91e34ab1fbcb1234d125ec8463bcd9b3bad23b1
**Branch**: main
**Repository**: rails-app-generator

## Research Question

Compile a baseline of what already exists in the codebase that Phase 4 (production deploy of the generator + dynamic `kamal-proxy` routing of previews + wildcard DNS/TLS + strict `--internal` Docker network) will inherit, build on, or replace. Document only what *is*, not what *should be*.

## Summary

Phase 3 closed at the local-PoC level on 2026-04-27 (commit `b91e34a`). The codebase now carries a fully wired preview pipeline: `Preview::PreviewManager` shells `docker build` / `docker run` / `docker network` / `curl /up`, hardens the container with `--cap-drop=ALL --security-opt=no-new-privileges --read-only --memory=512m --cpus=0.5 --pids-limit=100 --network=preview-internal`, and binds host ports `3000 + project.id` for iframe access at `http://localhost:#{port}`. `Project` carries a `preview_state` enum + `preview_container_id`, `preview_started_at`, `preview_error` columns; `StartPreviewJob` / `StopPreviewJob` / `CleanupIdlePreviewsJob` run on the `:preview` queue (1 thread); `PreviewsController` + 5 partials (`_pane`, `_stopped`, `_starting`, `_running`, `_failed`) drive the UI; `instruction.requested` auto-stops a running preview; a `preview_reset.rb` initializer reconciles orphans on boot.

The Phase 3 implementation took explicit fallbacks because of Docker Desktop / macOS limitations and labelled them "Phase 4 reintroduces": the `preview-internal` network is created **without** `--internal` (vpnkit drops `-p` host port mappings on `--internal` networks); preview egress isolation, distinct hostnames per preview, wildcard TLS, and DNS are all parked. `docs/03-plans/02-phase-3-preview-isolation.md` is the closest thing to a Phase 4 design document — its "MVP" / "Production" rollout phases sketch the exact surface Phase 4 will activate (kamal-proxy + `--internal` + per-container network in the limit). `docs/01-vision/02-user-journey.md:428` already names the Phase 4 endpoint shape: `https://#{id}.preview.<domain>`.

The Rails-default Kamal scaffolding for the **generator itself** (its own production deploy, separate from preview routing) is checked in but never used: `Dockerfile`, `config/deploy.yml`, `Gemfile:35` `gem "kamal", require: false`, `bin/kamal`, `.kamal/secrets`. `config/deploy.yml` is a pristine Kamal 1.x template with placeholder server `192.168.0.1`, registry `localhost:5555`, kamal-proxy section commented out, persistent volume `rails_app_generator_storage:/rails/storage`, builder arch `amd64`. Nothing in the codebase has ever been deployed; Phase 2 ran `rails new --skip-kamal` and `bin/dev` is the current run mode.

Phase 4-specific decisions are not yet documented anywhere. Open questions raised by the Phase 3 kickoff research (`thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md` § Open Questions) that surfaced as Phase 4 territory: kamal-proxy install path on the host (Kamal 1.x normally ships it via deploy machinery; standalone install is a separate decision), Selenium/system-test viability on a remote host, and DNS provisioning.

## Detailed Findings

### Phase 4 anchor in `CLAUDE.md`

`CLAUDE.md:9` — Phase 4 is named in the project status line as the next candidate:

> **Phase 4** (production deploy on Hetzner/DO with kamal-proxy + DNS + wildcard cert + strict `--internal` network) is the next candidate.

`CLAUDE.md:49` — Conventions section explicitly carries the deferral:

> The `preview-internal` Docker network is created without `--internal` on Docker Desktop (host port mapping wouldn't work otherwise) — Phase 4 reintroduces strict egress isolation on a Linux production host.

These are the only two `CLAUDE.md` mentions of Phase 4. There is no Phase 4 plan in `docs/03-plans/` or `thoughts/shared/plans/`.

### What Phase 4 inherits from Phase 3 (preview pipeline as it exists today)

#### `Preview::PreviewManager` — the container orchestrator

`lib/preview/preview_manager.rb` (215 lines) is the single Ruby class driving Docker. Surface relevant to Phase 4:

- **Network creation** (`lib/preview/preview_manager.rb:77-83`): `ensure_network!` runs `docker network inspect preview-internal`; on failure, runs `docker network create preview-internal` (NOT `--internal`). The fallback is documented inline at `lib/preview/preview_manager.rb:72-76`:
  > Step 3 smoke test on Docker Desktop / macOS confirmed `--internal` networks silently drop `-p` host port mappings (vpnkit limitation). [...] Phase 4 will reintroduce strict egress isolation on a Linux production host where `--internal` actually works with port-publish.
- **Container run** (`lib/preview/preview_manager.rb:141-172`): builds `docker run -d` with the security flags, **plus `-p #{port}:3000`** (host port mapping) and `-v #{workspace}/storage:/app/storage`. The host port mapping is what Phase 4 architecture replaces with kamal-proxy → container-IP routing.
- **Healthcheck** (`lib/preview/preview_manager.rb:174-187`): `curl -fsS -o /dev/null -m 2 http://localhost:#{preview_port}/up` against the host-mapped port. Phase 4's healthcheck location (still localhost from the generator's perspective if both run on the same host? or via kamal-proxy?) is not encoded here.
- **`preview.ready` event** (`lib/preview/preview_manager.rb:48-51`): `ActiveSupport::Notifications.instrument("preview.ready", project_id:, url: project.preview_url)`. `url` flows from `Project#preview_url`, which today returns `http://localhost:#{preview_port}`.
- **Boot orphan reset** (`lib/preview/preview_manager.rb:100-116`): `reset_orphans!` lists all containers via `docker ps -a --format '{{.Names}}'`, prefix-matches `preview-`, force-removes them, and flips any `:starting` / `:running` row to `:stopped` with `preview_error: "Reset on boot — process restarted while preview was running"`. This behaviour matters for Phase 4 because a Kamal redeploy of the generator restarts the Rails process.
- **Constants** (`lib/preview/preview_manager.rb:5-13`): `MEMORY_LIMIT="512m"`, `CPU_LIMIT="0.5"`, `PIDS_LIMIT=100`, `NETWORK="preview-internal"`, `BASE_TAG="preview-base:latest"`, `BUILD_TIMEOUT_SECONDS=8*60`, `HEALTH_TIMEOUT_SECONDS=60`, `HEALTH_INTERVAL_SECONDS=1`, `ERROR_TRUNCATE=2_000`.
- **Failure handling** (`lib/preview/preview_manager.rb:189-200`): on any exception, `docker rm -f` the container, `docker image rm -f` the project tag, set `preview_state=:failed`, store truncated `preview_error`, broadcast.
- **Injectable runner** (`lib/preview/preview_manager.rb:20-26`): `initialize(runner: SystemRunner.new, …)`. The pattern from Phase 2's `ExecuteInstructionJob#run_roast_subprocess` carries forward — Phase 4 additions can be unit-tested with the same `SystemRunner` injection seam.

`lib/preview/system_runner.rb` (17 lines) wraps `Open3.capture3` and `system(*cmd)` and returns a `Result` struct.

#### Jobs

- `app/jobs/start_preview_job.rb` — `queue_as :preview`; thin wrapper calling `Preview::PreviewManager.new.start(project)`.
- `app/jobs/stop_preview_job.rb` — `queue_as :preview`; thin wrapper calling `Preview::PreviewManager.new.stop(project)`.
- `app/jobs/cleanup_idle_previews_job.rb` — `queue_as :preview`; `IDLE_TIMEOUT = 30.minutes`; finds `preview_state=:running` rows with `preview_started_at < 30.minutes.ago` and enqueues `StopPreviewJob`. Recurring schedule from `config/recurring.yml` (every 5 min, all environments).

#### Controller + UI

- `app/controllers/previews_controller.rb` — nested under `projects`; `create` flips state to `:starting` synchronously and enqueues `StartPreviewJob`; guards against double-click via 409 Conflict if state isn't `:stopped`/`:failed`; `destroy` enqueues `StopPreviewJob`. Both render a turbo_stream replace of `#preview` with `previews/pane`.
- `app/helpers/previews_helper.rb` — `preview_pane_partial(project)` maps `preview_state` → partial name (Memory: `feedback_no_logic_in_views.md` — branching belongs in the helper).
- `app/views/previews/_pane.html.erb` — wrapper, renders the state-specific partial.
- `app/views/previews/_stopped.html.erb` — "▶ Start preview" button.
- `app/views/previews/_starting.html.erb` — "⏳ Starting preview…" placeholder.
- `app/views/previews/_running.html.erb` — iframe with `sandbox="allow-same-origin allow-scripts allow-forms"`, link to `project.preview_url` opening in a new tab, "⏹ Stop" button.
- `app/views/previews/_failed.html.erb` — error pre block + "↻ Retry" button.

#### Project model — the data the URL depends on

`app/models/project.rb`:

- `preview_state` enum: `stopped:0, starting:1, running:2, failed:3`, default `:stopped`, `prefix: :preview`.
- `preview_url`: returns `nil` unless `preview_running?`; otherwise `"http://localhost:#{preview_port}"`. **This is the line that flips on a domain switch.**
- `preview_port`: `3000 + id`. Phase 4 architecture has no host port (kamal-proxy talks to the container IP), so this method becomes either internal-only or unused.

Schema columns added in Phase 3 Step 2 (commit `bcf5765`): `preview_state` (integer, default 0), `preview_container_id` (string), `preview_started_at` (datetime), `preview_error` (text).

#### Routes

`config/routes.rb`:

```ruby
resources :projects, only: [ :new, :create, :show ] do
  resources :messages, only: [ :create ]
  resource  :preview,  only: [ :create, :destroy ]
end
```

#### Event subscribers

`config/initializers/event_subscribers.rb`:

- 3 subscribers on `instruction.requested`: enqueue `ExecuteInstructionJob`, broadcast active revisions, enqueue `StopPreviewJob` (lines 25-28). The auto-stop-on-generation behaviour is a Phase 3 invariant, motivated by:
  > production-mode containers don't autoload, so a running preview shows stale code mid-generation regardless of whether we'd kept it up. Stopping here also frees the bind-mounted SQLite for migrations the agent may run during the build.
- `preview.ready` is **emitted** by `PreviewManager#start` but **not subscribed**. The container partial re-renders directly via `broadcast_replace_to` inside `PreviewManager#broadcast`.

#### Boot-time reset initializer

`config/initializers/preview_reset.rb`:

```ruby
Rails.application.config.after_initialize do
  next if Rails.env.test?
  command = ARGV.first.to_s
  next unless %w[server runner console s c].include?(command) || ENV["BIN_DEV"] == "1"

  Preview::PreviewManager.reset_orphans!
end
```

Gates on `ARGV.first` to avoid running during `rails db:migrate` etc. The `bin/thrust ./bin/rails server` production entrypoint (`Dockerfile:CMD`) starts with `server` after the `bin/thrust` indirection — this needs verification under Kamal-deployed runtime since `ARGV` after `thrust` exec may differ.

#### Skeleton + skeleton-overlay (workspace seed)

`lib/preview/skeleton/` is a pristine `rails new` output (regenerable via `bin/preview-regen-skeleton`). `lib/preview/skeleton-overlay/` carries files we own, copied on top of the skeleton at `ExecuteInstructionJob#init_rails_app` time. The overlay includes:

- `bin/preview-entrypoint` — `bin/rails db:prepare && exec bin/rails server -b 0.0.0.0 -p 3000`. Referenced by `lib/preview/Dockerfile:ENTRYPOINT`.
- `.dockerignore` — excludes `.git/`, `log/*`, `tmp/*`, `db/*.sqlite3*`, `node_modules/`, `.bundle/`, `vendor/bundle/`.
- `config/initializers/preview_iframe.rb` — strips `X-Frame-Options` from default headers. Required because in Phase 3 PoC the generator (`localhost:3000`) and the preview (`localhost:3038`) are different origins (different ports), so the default `SAMEORIGIN` blocks framing. **Phase 4's distinct hostnames keep the cross-origin framing requirement; this initializer stays relevant.**

Regen scripts: `bin/preview-regen-skeleton` runs `rails new` in tmpdir, rsyncs into `lib/preview/skeleton/`, then `bundle lock --add-platform x86_64-linux aarch64-linux` so Linux preview builds work with the same lockfile. `bin/preview-rebuild-base` builds `preview-base:latest` from `lib/preview/Dockerfile.base` (~25s warm, 894 MB image as of 2026-04-27).

#### Preview Dockerfiles

`lib/preview/Dockerfile.base` (16 lines): `FROM ruby:${RUBY_VERSION}-slim`, installs `build-essential libsqlite3-dev libyaml-dev curl git`, sets `BUNDLE_PATH=/usr/local/bundle`, copies `skeleton/Gemfile{,.lock}`, runs `bundle install`. Build context is `lib/preview/`.

`lib/preview/Dockerfile` (22 lines): `FROM ${BASE_TAG}` (default `preview-base:latest`), `COPY . .`, `bundle install` (gems added by revisions on top of skeleton), `bin/rails tailwindcss:build`, `RAILS_ENV=development`, `RAILS_LOG_TO_STDOUT=1`, `EXPOSE 3000`, `ENTRYPOINT ["/app/bin/preview-entrypoint"]`.

#### Queue configuration

`config/queue.yml` declares the `:preview` queue with `threads: 1, processes: 1`. Same shape as `:generation`.

`config/recurring.yml`: `cleanup_idle_previews` every 5 min in all environments; `clear_solid_queue_finished_jobs` every hour in production only.

#### E2E test gating

`test/integration/preview_lifecycle_test.rb` (skipped unless `E2E_PREVIEW=1`) exercises the full Docker chain: skeleton workspace seed → `Preview::PreviewManager.new.start(project)` → curl `/up` → `stop`. `WALL_TIME_BUDGET = 180`. Test stubs `preview_port` because fixture-loaded projects have hashed huge IDs that would overflow TCP 16-bit port range when added to `3000 + id`.

### What Phase 4 explicitly takes on (collected deferrals)

From `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` § "What We're NOT Doing" (lines 49-65):

- **No deploy of the generator** to Hetzner/DigitalOcean (line 53). Generator stays on `bin/dev`.
- **No `kamal-proxy`. No DNS. No wildcard TLS.** (line 54).
- **No production-mode preview container** (line 55). Containers run `RAILS_ENV=development` for better error pages and to skip `SECRET_KEY_BASE` ceremony. Phase 4 plan inherits this choice unless explicitly revisited.
- **No subdomain routing** (`<id>.preview.domain.com`) (line 56). Iframe uses port-mapped `localhost`.
- **No multi-server LB, gVisor, Firecracker, monitoring dashboards** (line 57).
- **Cookie isolation** between generator and preview is structural-not-enforced (line 64). Both run on `localhost`, sharing per-host cookie jar; cookie *names* differ (`_rails_app_generator_session` vs `_rails_application_session`) so they don't collide functionally. > "Phase 4's distinct hostnames per preview properly isolate jars; PoC accepts the cohabitation."
- **Network egress isolation deferred — `--internal` fallback taken** (line 65).
  > Phase 4 will reintroduce strict egress isolation via a dedicated subnet + iptables on the production host (Linux native iptables, no vpnkit/qemu intermediary).

From `lib/preview/preview_manager.rb:75-76`:
> Phase 4 will reintroduce strict egress isolation on a Linux production host where `--internal` actually works with port-publish.

From `docs/02-architecture/03-tech-stack.md:191`:
> Phase 4 will add `kamal-proxy` for routing previews behind a wildcard subdomain.

From `docs/01-vision/02-user-journey.md:428`:
> **Phase 4**: `https://#{id}.preview.<domain>` via kamal-proxy + wildcard cert.

### Phase 4 architecture sketch (from existing analysis)

`docs/03-plans/02-phase-3-preview-isolation.md` already contains the architecture diagram and component contracts that Phase 4 will activate. The doc is titled "Phase 3 — Preview Isolation analysis with Kamal" but its endpoint vision is the Phase 4 production target:

`docs/03-plans/02-phase-3-preview-isolation.md:44-74` — the canonical diagram:

```
Internet
    │
    ▼
┌──────────────────────────────────────────┐
│  kamal-proxy (host, port 443)            │
│  Routing:                                │
│    app.domain.com → generator:3000       │
│    *.preview.domain.com → containers     │
├──────────────────────────────────────────┤
│  Generator app (Kamal deploy)             │
│  Preview-N (Docker)                       │
│  Docker network: preview-internal         │
│  (--internal = no outbound internet)      │
└──────────────────────────────────────────┘
```

Component contracts:

- **kamal-proxy as router** (`docs/03-plans/02-phase-3-preview-isolation.md:78-104`): standalone Go binary, HTTP API, dynamic add/remove without restart.
  ```bash
  kamal-proxy deploy preview-123 --target 172.18.0.5:3000 --host 123.preview.domain.com
  kamal-proxy remove preview-123
  kamal-proxy list
  ```
- **DNS** (line 102-104): wildcard `*.preview.domain.com` → A record. kamal-proxy holds explicit `--host` per preview; no proxy-side wildcard needed.
- **PreviewManager additions** (lines 217-222 in the analysis sketch): after `docker run`, `docker inspect` to get container IP, then `kamal-proxy deploy preview-#{project.id} --target #{ip}:3000 --host #{project.id}.preview.domain.com`. On stop, `kamal-proxy remove preview-#{project.id}`.
- **Rollout phases** (lines 322-341):
  - PoC (= shipped Phase 3): `docker run` + `localhost:{port}`, no kamal-proxy, manual cleanup.
  - MVP (= Phase 4 first cut): kamal-proxy + `--internal` network + PreviewManager + auto-cleanup + base image + 10-preview cap.
  - Production (= Phase 4+): separate network per container, monitoring, multi-server LB, optional gVisor/Firecracker.
- **Solved vs. accepted risks** (lines 304-318): the analysis already classifies "container-to-container visibility on shared network" as accepted-for-now ("separate networks per container in the future") and "Docker escape" as kernel-level / not-our-application's-problem.

### Existing Kamal scaffolding for the generator (Rails-default, never used)

#### `Dockerfile` (78 lines)

Standard Rails 8 multi-stage production Dockerfile, generated by `rails new`:

- `FROM ruby:4.0.2-slim AS base`, `WORKDIR /rails`.
- Installs `curl libjemalloc2 libvips sqlite3`.
- ENV: `RAILS_ENV=production`, `BUNDLE_DEPLOYMENT=1`, `BUNDLE_PATH=/usr/local/bundle`, `BUNDLE_WITHOUT=development`, `LD_PRELOAD=…libjemalloc.so`.
- Build stage: `bundle install`, `bundle exec bootsnap precompile`, `SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile`.
- Final stage: non-root user `rails:1000`, `ENTRYPOINT ["/rails/bin/docker-entrypoint"]`, `EXPOSE 80`, `CMD ["./bin/thrust", "./bin/rails", "server"]`.

This is for the **generator itself**, separate from `lib/preview/Dockerfile`. The Phase 3 plan (analysis line 234-236) is explicit:
> we never use a Dockerfile from the generated app.

#### `config/deploy.yml` (120 lines, Kamal 1.x template)

Pristine Rails-generated. Notable values:

- `service: rails_app_generator`, `image: rails_app_generator`.
- `servers.web: [192.168.0.1]` — placeholder.
- `registry.server: localhost:5555` — placeholder.
- `env.secret: [RAILS_MASTER_KEY]`, `env.clear.SOLID_QUEUE_IN_PUMA: true`.
- `volumes: [rails_app_generator_storage:/rails/storage]` — persistent volume for SQLite + Active Storage.
- `asset_path: /rails/public/assets`.
- `builder.arch: amd64`.
- `proxy.ssl: true / host: app.example.com` — **commented out**.
- `accessories: db / redis` — commented out.
- Aliases: `console`, `shell`, `logs`, `dbc`.
- Comment at line 12-15 (job role): "When you start using multiple servers, you should split out job processing to a dedicated machine." — relevant because preview build/run is heavyweight.

#### `.kamal/secrets`

Pulls `RAILS_MASTER_KEY=$(cat config/master.key)`. `KAMAL_REGISTRY_PASSWORD` is referenced as a future ENV. No production secrets in the file.

#### `Gemfile:35`

```ruby
gem "kamal", require: false
```

Present, inactive. `bin/kamal` exists as a stub.

#### `.dockerignore`

Excludes `.git`, `.bundle`, `tmp/`, `storage/`, `node_modules/`, `config/deploy*.yml`, `.kamal`. (Generator's own dockerignore — separate from `lib/preview/skeleton-overlay/.dockerignore` used for previews.)

### Generator-runtime concerns Phase 4 will encounter

- **Workspace storage on the prod host**: `Project.workspace_root` reads `RAILS_APP_GENERATOR_WORKSPACE_ROOT` ENV (default `~/projects/rails-app-generator-workspaces/`). The Kamal `volumes` directive currently maps `rails_app_generator_storage:/rails/storage` — workspaces are NOT under that path today. A preview's container mounts `<workspace>/storage:/app/storage` for SQLite persistence (`lib/preview/preview_manager.rb:165`). Phase 4 needs a persistent volume strategy for the workspace tree.
- **Build host = run host**: Per-project preview builds shell `docker build -f lib/preview/Dockerfile <workspace>` (`lib/preview/preview_manager.rb:128-138`). The workspace lives on the host filesystem; the generator process and the Docker daemon must be on the same host.
- **Base image presence**: Each preview build references `BASE_TAG=preview-base:latest`. `bin/preview-rebuild-base` builds it locally. On a remote host, this image must exist before any preview start succeeds (or be pulled from a registry).
- **`SOLID_QUEUE_IN_PUMA: true`** (`config/deploy.yml`): Solid Queue runs inside the web Puma process. Preview build/run jobs run there. Phase 4 may keep this or switch to the commented `job` role + dedicated worker host.
- **Boot reset gating** (`config/initializers/preview_reset.rb:8-9`): only runs if `ARGV.first ∈ {server, runner, console, s, c}` or `BIN_DEV=1`. `bin/thrust ./bin/rails server` (the `Dockerfile` `CMD`) — `ARGV` after `thrust` exec becomes `["server"]`, which matches.
- **Subprocess ENV envelope**: `bin/roast` (`bin/roast:1`) is the wrapper that scrubs `ANTHROPIC_*` ENV and pins frum PATH from `.ruby-version`. On a production host without frum, the PATH-pinning logic needs review. (Phase 4 deployment surface, separate from preview routing.)

### Phase 4 surface in the analysis canon — open questions already noted

`thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md:307-326` listed open questions at Phase 3 activation. Several were Phase-4 territory and remained unresolved when Phase 3 closed:

- **Q5** Selenium / system tests on remote hosts (memory `project_verify_no_system_tests.md`). Parked.
- **Q7** `kamal-proxy` install path (line 323):
  > Kamal 1.x ships kamal-proxy via its own deploy machinery; standalone install path is its own decision.

The Phase 3 implementation plan's `## What We're NOT Doing` section (lines 49-65) extends this with: deploy host choice (Hetzner vs. DO), domain registration, wildcard TLS issuance flow, separate-network-per-container threshold, and the cookie/iframe semantics under cross-origin.

### Workflow canon — W3 contract that Phase 4 must keep

`docs/02-architecture/01-workflows-and-decisions.md:138-154`:

```
W3.1  Stop existing preview (if any)
W3.2  bundle install (shared cache)
W3.3  rails db:prepare
W3.4  rails server -p {port}    [PHASE 3: replaced by docker run]
W3.5  Verify the server responds (health check)
W3.6  Push preview URL via Turbo Stream
```

**Implementation**: > "W3 is implemented as a plain Ruby class (`lib/preview/preview_manager.rb`), not a Roast workflow — every step is deterministic and Roast's value (LLM/agent integration) does not apply."

**Trigger model in Phase 3**: > "`start` is user-initiated (button click → `PreviewsController#create`); `stop` is user-initiated OR auto-fired by the `instruction.requested` subscriber [...]. The `instruction.completed` subscriber does NOT auto-start; preview is a deliberate user-driven feature."

The W3 step list does not currently include a "register route with kamal-proxy" step — this would be a new sub-step in Phase 4 (between W3.4-equivalent `docker run` and W3.5 healthcheck) or after the healthcheck.

### Pre-declared event taxonomy Phase 4 may extend

`docs/02-architecture/02-layer-integration.md:50-52`:

```
"preview.ready"            # preview started → payload: { project_id:, url: }
```

Already emitted (`lib/preview/preview_manager.rb:48`). No subscriber in `config/initializers/event_subscribers.rb` — the container partial broadcasts directly via `PreviewManager#broadcast`. Phase 4 might introduce `preview.routed` (post-kamal-proxy registration) or attach to `preview.ready` for kamal-proxy registration if registration moves into a subscriber. The subscriber rule (`docs/02-architecture/02-layer-integration.md:182-189`) constrains: only `perform_later` or `broadcast_*` allowed.

### Production-relevant memories and conventions

From `CLAUDE.md` Conventions section + `MEMORY.md`:

- **Roast runner** (CLAUDE.md:46): `bin/roast` default (Claude subscription wrapper); `bin/roast-openrouter` paid fallback. `bundle exec roast` directly bypasses ENV scrubbing — must not be called.
- **Preview infrastructure** (CLAUDE.md:49): preview Dockerfiles owned by this repo, never read from generated apps.
- Memory `project_ruby_version_prefix.md`: `.ruby-version` content has `ruby-` prefix; frum's dir layout omits it. `bin/preview-rebuild-base` strips the prefix when passing `RUBY_VERSION` to Docker.
- Memory `project_verify_no_system_tests.md`: no Selenium/headless-Chrome on remote hosts. Phase 3's preview verification uses host-side `curl /up`. Open-ended for any future feature needing browser automation.
- Memory `project_dev_cable_solid.md`: `cable.yml` must use `solid_cable` (not `async`) so broadcasts from Solid Queue worker reach the browser's web-process WebSocket. Production already uses `solid_cable` (Rails 8 default).
- Memory `feedback_state_by_absence.md`: encode "not running" by NULL columns + `preview_state == :stopped`, not by a separate boolean. Reflected in current `Project` schema.
- Memory `feedback_derive_dont_store.md`: `preview_url` is a method, not a column.
- Memory `feedback_no_logic_in_views.md`: `preview_pane_partial` lives in the helper.

## Code References

### Preview pipeline (Phase 3, what Phase 4 builds on)

- `lib/preview/preview_manager.rb:1-215` — Docker orchestration class; container lifecycle, healthcheck, orphan reset.
- `lib/preview/preview_manager.rb:75-76` — explicit `Phase 4 will reintroduce strict egress isolation` comment.
- `lib/preview/preview_manager.rb:77-83` — `ensure_network!` (creates `preview-internal` without `--internal`).
- `lib/preview/preview_manager.rb:141-172` — `run_container` with `-p #{port}:3000` (host port mapping).
- `lib/preview/system_runner.rb:1-17` — shell wrapper with `Open3` and a `Result` struct.
- `lib/preview/Dockerfile:1-22` — per-project preview image; `FROM ${BASE_TAG}`, ENTRYPOINT from overlay.
- `lib/preview/Dockerfile.base:1-16` — base image; bakes the skeleton's bundle.
- `lib/preview/skeleton-overlay/bin/preview-entrypoint` — `db:prepare && exec bin/rails server -b 0.0.0.0 -p 3000`.
- `lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb` — strips `X-Frame-Options`.
- `app/jobs/start_preview_job.rb`, `stop_preview_job.rb`, `cleanup_idle_previews_job.rb` — `:preview` queue.
- `app/controllers/previews_controller.rb:1-43` — POST/DELETE under `/projects/:id/preview`.
- `app/helpers/previews_helper.rb` — state → partial mapping.
- `app/views/previews/_*.html.erb` — 5 partials (`_pane`, `_stopped`, `_starting`, `_running`, `_failed`).
- `app/models/project.rb` — `preview_state` enum; `preview_url`, `preview_port` methods.
- `config/initializers/event_subscribers.rb:25-28` — `instruction.requested` → `StopPreviewJob`.
- `config/initializers/preview_reset.rb` — boot-time `reset_orphans!`.
- `config/queue.yml` — `:preview` queue declaration.
- `config/recurring.yml` — `cleanup_idle_previews` every 5 min, all envs.
- `config/routes.rb` — `resource :preview, only: [:create, :destroy]`.
- `bin/preview-rebuild-base` — base image build (strips `ruby-` from `.ruby-version`).
- `bin/preview-regen-skeleton` — refresh skeleton from `rails new`; runs `bundle lock --add-platform x86_64-linux aarch64-linux`.
- `test/integration/preview_lifecycle_test.rb` — gated `E2E_PREVIEW=1` Docker chain test.

### Generator-runtime / Kamal scaffolding (idle, never deployed)

- `Dockerfile:1-78` — Rails 8 default multi-stage production Dockerfile.
- `config/deploy.yml:1-120` — Kamal 1.x template, placeholder server `192.168.0.1`, registry `localhost:5555`, `proxy.ssl` commented out, persistent volume `rails_app_generator_storage:/rails/storage`, `builder.arch: amd64`.
- `.kamal/secrets` — `RAILS_MASTER_KEY=$(cat config/master.key)`.
- `Gemfile:35` — `gem "kamal", require: false`.
- `bin/kamal` — Kamal CLI stub.
- `bin/docker-entrypoint` — `db:prepare` shim called by `Dockerfile:ENTRYPOINT`.
- `.dockerignore` — excludes `config/deploy*.yml`, `.kamal`, `storage/`.

### Phase 4 design surface (lives in Phase 3 docs)

- `docs/03-plans/02-phase-3-preview-isolation.md:9-40` — Kamal split: full Kamal for generator, kamal-proxy standalone for preview routing, `docker run` direct for preview lifecycle.
- `docs/03-plans/02-phase-3-preview-isolation.md:44-74` — Architecture diagram (Internet → kamal-proxy:443 → containers on `preview-internal`).
- `docs/03-plans/02-phase-3-preview-isolation.md:78-104` — kamal-proxy as standalone router; dynamic deploy/remove; wildcard DNS pattern.
- `docs/03-plans/02-phase-3-preview-isolation.md:108-158` — Docker security flags + `--internal` network model + SQLite per-container DB.
- `docs/03-plans/02-phase-3-preview-isolation.md:217-222` — `register_route` sketch invoking `kamal-proxy deploy --target IP:3000 --host id.preview.domain.com`.
- `docs/03-plans/02-phase-3-preview-isolation.md:304-318` — solved vs. accepted risks.
- `docs/03-plans/02-phase-3-preview-isolation.md:322-341` — PoC / MVP / Production rollout phases.
- `docs/01-vision/02-user-journey.md:417-432` — Vision Step 5 (Preview); line 428 names Phase 4 endpoint shape.
- `docs/02-architecture/01-workflows-and-decisions.md:138-154` — W3 canonical step list + implementation note.
- `docs/02-architecture/02-layer-integration.md:50-52` — pre-declared `preview.ready` event.
- `docs/02-architecture/02-layer-integration.md:182-189` — subscriber rule (only `perform_later` or `broadcast_*`).
- `docs/02-architecture/03-tech-stack.md:189-191` — Phase 4 kamal-proxy note in tech stack.

### Phase 3 implementation plan — sections naming Phase 4

- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:14` — "Phase 3 = local PoC only. Production deploy + kamal-proxy + DNS + wildcard cert is Phase 4."
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:49-65` — "What We're NOT Doing" — every line that says "Phase 4" enumerates a deferred concern.
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:432` — Step 3 fallback rationale: > "Phase 4 will reintroduce strict egress isolation via dedicated subnet + iptables."
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:1255` — Step 9 canon update naming Phase 4 endpoint shape.
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:1266` — Step 9 tech stack update reserving "Phase 4 will add: kamal-proxy".
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:1270` — Step 9 CLAUDE.md status template.

## Architecture Documentation

### Patterns the preview pipeline established that Phase 4 inherits

1. **Subprocess orchestration via injectable runner** — `Preview::PreviewManager.new(runner: SystemRunner.new)`. Mirrors `ExecuteInstructionJob#run_roast_subprocess` (Phase 2 Step 5). Phase 4's `kamal-proxy deploy / remove` calls plug into the same `@runner.run("kamal-proxy", …)` shape, unit-testable via the same fake-runner technique.

2. **Idempotent lifecycle entry points** — `start(project)` calls `stop(project)` first if a container exists; `stop(project)` is a no-op when `preview_container_id` is nil. State + DB columns are the source of truth, reconciled at boot via `reset_orphans!`.

3. **Event-bus boundaries** — every cross-layer hop goes through `ActiveSupport::Notifications`; subscribers do only `perform_later` or `broadcast_*`. Phase 4 additions (e.g., kamal-proxy registration on preview start) fit either inside `PreviewManager#start` (Step 4 of W3) or as a new event + subscriber + job.

4. **ENV-overridable filesystem roots** — `RAILS_APP_GENERATOR_WORKSPACE_ROOT` (Phase 2). The pattern extends naturally to Phase 4 host-specific configuration (kamal-proxy socket, registry, preview domain).

5. **Per-queue concurrency in Solid Queue** — `:generation` (1), `:preview` (1), `:default + :mailers` (3). Phase 4 may add a `:deploy` or `:routing` queue or stay on `:preview`.

6. **Deterministic W3 as plain Ruby, not Roast** — preview is the only workflow that doesn't go through Roast. Phase 4 additions (kamal-proxy registration) preserve this.

7. **State by absence** — Memory `feedback_state_by_absence.md`. Preview state is encoded by `preview_state: :stopped` + NULL columns, not by a separate "running?" boolean.

8. **Dockerfile owned by this repo, never the generated app** — Phase 3 invariant carried into Phase 4 unchanged.

9. **Standard Ruby + frum PATH pinning** — `.ruby-version` carries `ruby-` prefix; production must replicate the strip.

### Patterns Phase 4 will introduce (named in canon, not yet in code)

- **Standalone kamal-proxy invocation** — calling the binary directly outside its Kamal-deploy context. No precedent in the codebase.
- **Per-preview hostname routing** — `<id>.preview.<domain>`. Replaces port-publish.
- **Strict `--internal` network with port-publish** — works on Linux, blocked on Docker Desktop. The Phase 3 fallback line is the gate.
- **Wildcard TLS via Let's Encrypt (kamal-proxy built-in)** — first TLS surface in the codebase.
- **Possible `:deploy` job role split** — commented-out at `config/deploy.yml:12-15` (job hosts).
- **Per-container subnet strategy** — analysis line 339, "separate networks per container in the future".

## Historical Context (from thoughts/)

- `./thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md` — full kickoff research that shaped Phase 3 implementation; § Open Questions (lines 307-326) carries Phase 4-relevant unresolved items: kamal-proxy install path, Selenium/system-tests on remote hosts, DNS provisioning, per-container network threshold.
- `./thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` — implementation plan that just shipped; § "What We're NOT Doing" is the comprehensive Phase 4 deferral list.
- `./thoughts/shared/handoffs/general/2026-04-27/14-59-28_phase-3-steps-1-6-complete-resume-from-step-7.md` — handoff document at end of Phase 3 Step 6; Step 5 of the gotchas section explicitly captures the `--internal` fallback for Phase 4. (File present but currently untracked per `git status`.)
- `./thoughts/shared/research/2026-04-20/phase-2-step-5-execute-instruction-job.md` — establishes the subprocess + injectable runner pattern that `Preview::PreviewManager` follows; Phase 4's kamal-proxy calls would adopt the same shape.
- `./thoughts/shared/plans/2026-04-21/phase-2-step-6-events-turbo-revisions.md` — Turbo broadcast patterns; Phase 4 keeps these unchanged when iframe URLs flip.

## Related Research

- `./thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md` — direct predecessor; describes the codebase state on the eve of Phase 3 implementation. Most of its "current state" findings are now superseded by Phase 3 commits, but its analysis of `docs/03-plans/02-phase-3-preview-isolation.md` (which doubles as the Phase 4 design source) is still valid.

No prior research or plan documents specifically scoped to Phase 4 exist in `thoughts/`. This document is the first.

## Open Questions

These are questions that the existing analysis docs flag as still-open as of Phase 3 close — not new questions introduced by this research. They map directly onto the Phase 4 surface area:

1. **kamal-proxy install path on the production host** (`thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md:323`) — Kamal 1.x bundles kamal-proxy via its own deploy machinery; standalone install requires its own decision (manual install, separate role in `deploy.yml`, sidecar accessory, etc.).
2. **Hetzner vs. DigitalOcean** — `CLAUDE.md:9` says "Hetzner/DO" without committing.
3. **Domain registration + DNS provider** — wildcard `*.preview.<domain>` requires a chosen apex domain and a DNS provider supporting fast wildcard A records.
4. **Wildcard TLS issuance flow** — kamal-proxy's Let's Encrypt integration vs. a manually issued wildcard cert; rate limits with per-preview `--host` patterns.
5. **Workspace storage on the prod host** — `~/projects/rails-app-generator-workspaces/` doesn't exist on a fresh Hetzner/DO box; needs a Kamal volume directive analogous to `rails_app_generator_storage:/rails/storage`.
6. **Job topology** — keep `SOLID_QUEUE_IN_PUMA: true` (current `config/deploy.yml:35`) or split a `job` role to a dedicated host (commented at line 12-15)?
7. **Image registry** — `registry.server: localhost:5555` is a placeholder. Real choice: ghcr.io / Docker Hub / DigitalOcean Container Registry / Hetzner registry.
8. **Per-container subnet threshold** — `docs/03-plans/02-phase-3-preview-isolation.md:339` mentions "separate network per container in the future" without pinning a trigger.
9. **Strict egress isolation mechanism** — `--internal` flag alone, or `--internal` + iptables on a dedicated subnet (`thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:65,432`).
10. **Selenium / headless-Chrome on remote host** — Memory `project_verify_no_system_tests.md` parks this; resolved or restated for Phase 4?
11. **`Project#preview_url` rewrite mechanics** — currently `"http://localhost:#{preview_port}"`. Phase 4 wants `"https://#{id}.preview.<domain>"`. Where does `<domain>` come from (ENV, credentials, settings table)?
12. **`preview_port` deprecation** — when host port-publish goes away (kamal-proxy talks to container IP), `preview_port` becomes either internal-only or unused.
13. **Cross-origin iframe semantics** — `app/views/previews/_running.html.erb` uses `sandbox="allow-same-origin allow-scripts allow-forms"`. Under different origins (generator vs preview), `allow-same-origin` no longer makes them same-origin (browser scoping is by URL origin); the cookie cohabitation question (`thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md:64`) is structurally fixed but the iframe attributes need re-validation.
14. **Boot-time orphan-reset under Kamal restart** — `config/initializers/preview_reset.rb` checks `ARGV.first ∈ {server, runner, console, s, c}`. Under `bin/thrust ./bin/rails server` exec chain, ARGV evolution is worth double-checking — the production smoke-test of `reset_orphans!` is implicit, not asserted.
15. **E2E test mode** — `test/integration/preview_lifecycle_test.rb` currently curls `http://localhost:#{preview_port}/up`. With kamal-proxy in front, the test either keeps a localhost mode (skip kamal-proxy) or grows a separate gating env for the routed flow.
