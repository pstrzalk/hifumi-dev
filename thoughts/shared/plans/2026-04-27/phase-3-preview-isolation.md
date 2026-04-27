---
date: 2026-04-27
author: Paweł Strzałkowski
phase: 3
status: ready-for-implementation
preceding: docs/03-plans/02-phase-3-preview-isolation.md (analysis)
research: thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md
---

# Phase 3 — Preview Isolation (Local PoC) — Implementation Plan

## Overview

Add a hardened, button-driven preview pane to the generator so the user can launch the generated Rails app in an isolated Docker container and view it in a sandboxed iframe alongside the chat. Phase 3 = **local PoC only**. Production deploy + kamal-proxy + DNS + wildcard cert is **Phase 4**.

End-state demo on a developer laptop: open project 38 → side-by-side layout, chat on the left, preview pane on the right with a "▶ Start preview" button → click → ~10-30 s build/boot → iframe loads `http://localhost:3038` showing the generated todo-list app, fully functional, hardened by `--cap-drop=ALL --read-only --network=preview-internal --memory=512m --cpus=0.5`. Click "⏹ Stop" → container removed, pane returns to "Start" state. After 30 min idle → auto-stopped by recurring job.

## Current State Analysis

- Phase 2 closed at Step 7 (`CLAUDE.md`); generator runs locally via `bin/dev`; gated E2E test green on project 38.
- Generated apps live at `~/projects/rails-app-generator-workspaces/project_<id>/` (env-overridable via `RAILS_APP_GENERATOR_WORKSPACE_ROOT`); created by `ExecuteInstructionJob#prepare_workspace` shelling `rails new`.
- `Project` has only `name` column. No preview state. No iframe in `app/views/projects/show.html.erb`. No `preview.*` events emitted. No `lib/preview/` directory. The Rails-default `Dockerfile` and `config/deploy.yml` exist but are unused (Phase 2 used `--skip-kamal`).
- `preview.ready` is pre-declared in canon (`docs/02-architecture/02-layer-integration.md:50-52`) but no producer/subscriber yet.
- W3 in canon (`docs/02-architecture/01-workflows-and-decisions.md:137-150`) is a 6-step deterministic sequence; lists `rails server` as the run mechanism — Phase 3 replaces with `docker run`.
- Claude CLI runs with `skip_permissions!` in `lib/roast/revision_workflow.rb` — explicit Phase 3 motivation per `spikes/roast/findings.md:96-111` (untrusted code needs container boundary before any non-developer use).

## Desired End State

A user on the project page can click "▶ Start preview", wait 10-30 s, and see the generated app running in an iframe at `http://localhost:#{3000 + project.id}` rendered in a sandboxed iframe. Stop is a button click. New generation auto-stops the running preview. Idle previews auto-stop after 30 min. Container is hardened (memory/cpu/pids capped, all caps dropped, no-new-privileges, read-only fs, internal network, sqlite db on host volume). Build cost amortized by a pre-built base image carrying the skeleton's gems.

Verifiable by:
- `bundle exec rails test` — full unit/controller/job suite green.
- `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb` — full Docker-build + run + healthcheck + stop chain green.
- `bundle exec rails test test/integration/generate_todo_list_test.rb E2E_GENERATE=1` — Phase 2 chain still green after skeleton refactor.
- Manual click-through demo on project 38 (or a fresh project): start → iframe loads → click around → stop.
- `docker inspect preview-<id>` shows: `CapAdd=[]`, `CapDrop=[ALL]`, `ReadonlyRootfs=true`, `NetworkMode=preview-internal`, `Memory=536870912`, `NanoCpus=500000000`, `PidsLimit=100`, `SecurityOpt` includes `no-new-privileges`.

## Key Discoveries (from kickoff research)

- `preview.ready` event already named in canon; subscriber rule (`docs/02-architecture/02-layer-integration.md:182-189`) limits subscribers to `perform_later` or `broadcast_*`.
- Phase 2 established the subprocess-with-injectable-runner pattern (`ExecuteInstructionJob#run_roast_subprocess` at `app/jobs/execute_instruction_job.rb:126`) — `PreviewManager` follows the same shape so unit tests can stub Docker.
- Memory `feedback_derive_dont_store.md`: `preview_url` is a pure function of `project.id` → method, not column.
- Memory `feedback_state_by_absence.md`: encode "not running" by NULL columns + `preview_state == :stopped`, not by a separate "running?" boolean.
- Memory `feedback_no_service_objects.md`: no `app/services/`; domain code in `lib/<feature>/`; class names describe the thing, not "Service".
- Memory `feedback_no_logic_in_views.md`: state-branching for the preview pane goes in a helper, not the partial.
- Memory `project_ruby_version_prefix.md`: `.ruby-version` content is `ruby-X.Y.Z`; strip the `ruby-` prefix when building paths or passing to Docker.
- Memory `project_verify_no_system_tests.md`: no Selenium/headless-Chrome system tests on remote hosts. Preview verified via curl, not browser automation.

## What We're NOT Doing

Explicitly out of scope for Phase 3:

- **No deploy of the generator** to Hetzner/DigitalOcean. Generator stays on `bin/dev` locally. Phase 4.
- **No `kamal-proxy`**. No DNS. No wildcard TLS. Phase 4.
- **No production-mode preview container.** RAILS_ENV=development inside the preview container — better error pages for the user, no `SECRET_KEY_BASE` ceremony.
- **No subdomain routing** (`<id>.preview.domain.com`). Iframe uses port-mapped `localhost`. Phase 4.
- **No multi-server LB, gVisor, Firecracker, monitoring dashboards.** Phase 4+.
- **No manual "rebuild only" button** distinct from "Restart". Restart = stop + start (rebuild image).
- **No streaming of `docker build` progress** to the UI. Pane shows `:starting` until it flips to `:running` or `:failed`.
- **No persistence of preview logs** beyond `docker logs preview-<id>` (host-side, ad hoc).
- **No `Active Storage` mount.** Generated apps without Active Storage are unaffected; if a future generated app uses it, that's a follow-up.
- **No deferred-request handling change** (`docs/09-ideas/02-deferred-request-handling.md`). Stays as-is in Phase 2 deferred.
- **No name-on-Project change.** Discussed; deferred.
- **Cookie isolation between generator and preview is structural, not enforced.** Both run on `localhost`, so they share a per-host cookie jar in the browser. Cookie *names* differ (`_rails_app_generator_session` vs `_rails_application_session` — Rails derives the name from the Application module), so functionally they don't collide. Phase 4's distinct hostnames per preview properly isolate jars; PoC accepts the cohabitation.

## Implementation Approach

The plan is structured as **9 atomic commits** that each leave the codebase green. The sequence is roughly: refactor the workspace setup to use a pre-baked skeleton (unblocks fast Docker builds), add the data model, add the Docker image-build infra, add the domain class, add the job layer, wire it end-to-end with UI, add idle cleanup, gated E2E test, canon updates.

### Critical invariants

1. **Phase 2 stays green** at every step. The Step-1 skeleton refactor must keep `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` passing — observable behavior from the LLM agent's perspective is identical (it sees a fresh Rails app at the workspace path).
2. **`PreviewManager#start` is idempotent**. If a container exists for the project, stop it first. Single entry point — no separate `restart`.
3. **`PreviewManager` never reads a Dockerfile from the generated app** — always `lib/preview/Dockerfile` from this repo. Carries the security guarantee.
4. **Preview lifecycle is button-driven**, not auto-triggered on generation completion. The only auto-trigger is `instruction.requested` → `StopPreviewJob` (because production-mode containers don't autoload, the running preview shows stale code mid-generation regardless).
5. **Subscribers stay thin** per `docs/02-architecture/02-layer-integration.md:182-189`. New `preview.*` subscribers do only `perform_later` or `broadcast_*`.

---

## Step 1: Pre-baked Rails skeleton refactor

### Commit
`phase 3 step 1: lib/preview/skeleton + cp_r-based prepare_workspace (replace rails new)`

### Overview
Replace `ExecuteInstructionJob#rails_new` with `cp -r` of a checked-in skeleton + an overlay carrying our additions (the preview entrypoint script). The skeleton is a verbatim `rails new` output with a fixed `RailsApplication` module name; the overlay holds files we own. Saves the `rails new` template-processing cost (~30 s per project), eliminates a class of `rails new` failure modes, and gives Step 3's base image something stable to layer on top of. Phase 2 tests stay green.

### Changes Required

#### 1. Generate the skeleton (one-time)

Run **once** on a clean dir outside the repo:

```bash
cd ~/tmp
rails new rails_application \
  --css tailwind --database sqlite3 \
  --skip-jbuilder --skip-kamal --skip-ci --skip-git
```

Then `rsync` into the repo, stripping noise:

```bash
rsync -av --delete \
  --exclude='.git' --exclude='tmp/' --exclude='log/' \
  --exclude='node_modules/' --exclude='.bundle/' \
  ~/tmp/rails_application/ \
  /Users/pawel/projects/rails-app-generator/lib/preview/skeleton/
```

Verify: `lib/preview/skeleton/config/application.rb` contains `module RailsApplication`.

#### 2. Skeleton overlay — files we own (separate from rails-new output)

**Decision**: `lib/preview/skeleton/` stays a verbatim `rails new` output (regenerable, no edits). Anything WE control lives in `lib/preview/skeleton-overlay/` and is copied **on top of** the skeleton at workspace-init time.

**File**: `lib/preview/skeleton-overlay/bin/preview-entrypoint` (mode 0755)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /app
bin/rails db:prepare
exec bin/rails server -b 0.0.0.0 -p 3000
```

This is referenced by Step 3's `lib/preview/Dockerfile` (`ENTRYPOINT ["/app/bin/preview-entrypoint"]`) and lands in every workspace by virtue of the overlay copy. Regenerating the skeleton (Step 1.3) doesn't touch this file.

**File**: `lib/preview/skeleton-overlay/.dockerignore`

Without this, Step 3's per-project `COPY . .` bakes the host's runtime state (sqlite DBs, logs, tmp caches, `.git/`) into every image — image bloat plus user data leaking into image layers.

```
# Build context excludes — applied to every per-project `docker build`.
# Keep narrow: anything that isn't safe to bake into an image layer.

.git/
.gitignore

log/*
!log/.keep

tmp/*
!tmp/.keep

# SQLite runtime files. Schema/migrations live elsewhere; the running DB
# itself is host state and gets re-mounted at runtime.
db/*.sqlite3
db/*.sqlite3-*

node_modules/
.bundle/
vendor/bundle/

# Editor/OS noise.
.DS_Store
.idea/
.vscode/
```

Note: the file lands in the workspace root via the overlay copy, so `docker build` (run with the workspace as context) picks it up automatically — no flag needed.

#### 3. `bin/preview-regen-skeleton`

**File**: `bin/preview-regen-skeleton` (new, executable, mode 0755)

```bash
#!/usr/bin/env bash
# Regenerate lib/preview/skeleton/ from a fresh `rails new`.
# Run when Rails ships a new minor and we want previews to inherit it.
# The skeleton-overlay/ tree is independent — never touched by this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
rails new rails_application \
  --css tailwind --database sqlite3 \
  --skip-jbuilder --skip-kamal --skip-ci --skip-git

rsync -av --delete \
  --exclude='.git' --exclude='tmp/' --exclude='log/' \
  --exclude='node_modules/' --exclude='.bundle/' \
  "$TMP/rails_application/" \
  "$REPO_ROOT/lib/preview/skeleton/"

# `rails new` produces a Gemfile.lock pinned to the host platform only
# (arm64-darwin on dev macs). Dockerfile.base builds on linux and would fail
# `bundle install` with "Your bundle only supports platforms [arm64-darwin]".
# Add both linux platforms so the same lockfile works in the base image.
( cd "$REPO_ROOT/lib/preview/skeleton" && \
  bundle lock --add-platform x86_64-linux aarch64-linux )

echo "Skeleton regenerated. Review with: git -C $REPO_ROOT diff lib/preview/skeleton/"
echo "Overlay (lib/preview/skeleton-overlay/) is unchanged and applied at workspace-init."
```

The same `bundle lock --add-platform` step must be run **once** by hand right after the initial `rsync` in Step 1.1 (the one-time skeleton bootstrap above), before checking in `lib/preview/skeleton/`. Otherwise Step 3's base image build fails.

#### 4. Refactor `ExecuteInstructionJob`

**File**: `app/jobs/execute_instruction_job.rb`

- Rename `rails_new` → `init_rails_app`.
- Body: `cp_r skeleton/` + `cp_r skeleton-overlay/` (overlay applied AFTER skeleton, wins on conflict) + `bundle install` + `git init` + initial commit.
- Keep `subprocess_env` (frum PATH) — `bundle install` and `git` need it.
- The existing `perform` gate `unless File.exist?(File.join(workspace, "Gemfile"))` is preserved; Gemfile still indicates initialization.

```ruby
def init_rails_app(workspace)
  FileUtils.mkdir_p(File.dirname(workspace))
  FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton')}/.",         workspace)
  FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton-overlay')}/.", workspace)

  Bundler.with_unbundled_env do
    ok = system(
      subprocess_env,
      "cd #{Shellwords.escape(workspace)} && bundle install --jobs 4"
    )
    raise "bundle install failed in #{workspace}" unless ok

    ok = system(
      subprocess_env,
      "cd #{Shellwords.escape(workspace)} && " \
      "git init -q && git add -A && " \
      "git -c user.email=generator@local -c user.name='Rails App Generator' " \
      "commit -q -m 'chore: skeleton baseline'"
    )
    raise "git init failed in #{workspace}" unless ok
  end
end
```

Rename the call in `perform`: `init_rails_app(workspace) unless File.exist?(File.join(workspace, "Gemfile"))`.

#### 5. Update tests
- `test/jobs/execute_instruction_job_test.rb` exists; current tests stub `run_roast_subprocess` (the LLM subprocess) and don't assert on the `rails new` shell string itself. They should pass with the rename and new body unchanged. **Sanity-grep** to confirm no test references `rails_new` or `"rails new"` as strings.
- **Add one new test**: after `init_rails_app(tmpdir)`, `tmpdir/config/application.rb` contains `module RailsApplication` AND `tmpdir/bin/preview-entrypoint` exists and is executable.

### Success Criteria

#### Automated:
- [x] `lib/preview/skeleton/config/application.rb` contains `module RailsApplication`.
- [x] `lib/preview/skeleton-overlay/bin/preview-entrypoint` exists, mode 0755.
- [x] `lib/preview/skeleton-overlay/.dockerignore` exists.
- [x] `bin/preview-regen-skeleton` exists, mode 0755.
- [x] `bundle exec rails test` green.
- [ ] `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` green. Wall-time should not regress; expected modest saving (~30 s) from skipping `rails new` template processing — most of E2E_GENERATE is LLM token-time, so don't expect a dramatic drop.

#### Manual:
- [x] Wipe a workspace (e.g. `rm -rf ~/projects/rails-app-generator-workspaces/project_test/`), call `ExecuteInstructionJob#init_rails_app` from `rails c`, verify: `module RailsApplication` in `config/application.rb`, `bin/preview-entrypoint` is present and executable, `git log` starts with `chore: skeleton baseline`.

**Pause for manual confirmation before proceeding to Step 2.**

---

## Step 2: `Project` schema + state machine

### Commit
`phase 3 step 2: Project preview state columns + enum`

### Overview
Add 4 columns to `projects` and an enum so the model can carry preview state. No infrastructure wired — just data model and predicates.

### Changes Required

#### 1. Migration

**File**: `db/migrate/<timestamp>_add_preview_state_to_projects.rb` (new)

```ruby
class AddPreviewStateToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :preview_state,        :integer, null: false, default: 0
    add_column :projects, :preview_container_id, :string
    add_column :projects, :preview_started_at,   :datetime
    add_column :projects, :preview_error,        :text
  end
end
```

#### 2. `Project` model

**File**: `app/models/project.rb`

```ruby
enum :preview_state, {
  stopped:  0,
  starting: 1,
  running:  2,
  failed:   3
}, default: :stopped, prefix: :preview

def preview_url
  return nil unless preview_running?
  "http://localhost:#{preview_port}"
end

def preview_port
  3000 + id
end
```

(`preview_running?` and `preview_starting?` etc. are auto-generated by the enum prefix.)

#### 3. Tests

**File**: `test/models/project_test.rb`

- `preview_url` returns nil when `preview_state != :running`.
- `preview_url` returns `"http://localhost:#{3000 + id}"` when `preview_state == :running`.
- `preview_port` is `3000 + id`.
- Default state is `:stopped`.

### Success Criteria

#### Automated:
- [x] `bundle exec rails db:migrate` clean.
- [x] `bundle exec rails test test/models/project_test.rb` green.
- [x] `bundle exec rails test` full suite green.

#### Manual:
- [x] In `rails c`: `Project.first.update!(preview_state: :running, preview_container_id: "abc"); Project.first.preview_url` returns `"http://localhost:#{3000 + first.id}"`.

---

## Step 3: Dockerfile + base image build infra

### Commit
`phase 3 step 3: lib/preview/Dockerfile{,.base} + bin/preview-rebuild-base`

### Overview
Add the standard preview Dockerfile (used by every per-project build) and the base-image Dockerfile (built rarely, carries the skeleton's bundle). The entrypoint script ships with the workspace via Step 1's overlay — Step 3 only references it. No Ruby integration yet — build infra only.

### Changes Required

#### 1. `lib/preview/Dockerfile.base`

**File**: `lib/preview/Dockerfile.base`

```dockerfile
ARG RUBY_VERSION=4.0.2
FROM ruby:${RUBY_VERSION}-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libsqlite3-dev libyaml-dev curl git \
    && rm -rf /var/lib/apt/lists/*

ENV BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=2

WORKDIR /app

# Bake the skeleton's bundle. Per-project images (FROM preview-base) only
# need to install gems added by the generated app on top of this.
COPY skeleton/Gemfile skeleton/Gemfile.lock ./
RUN bundle install
```

#### 2. `lib/preview/Dockerfile`

**File**: `lib/preview/Dockerfile`

```dockerfile
ARG BASE_TAG=preview-base:latest
FROM ${BASE_TAG}

WORKDIR /app

COPY . .

# Install any gems added by revisions on top of the skeleton's pre-bundled set.
RUN bundle install

# Pre-build Tailwind CSS (dev mode + Propshaft serves the result).
# No `|| true` — a CSS build failure must surface as a build failure.
RUN bin/rails tailwindcss:build

ENV RAILS_ENV=development \
    RAILS_LOG_TO_STDOUT=1 \
    PORT=3000

EXPOSE 3000

# Entrypoint ships with the workspace via Step 1's skeleton-overlay.
ENTRYPOINT ["/app/bin/preview-entrypoint"]
```

#### 3. `bin/preview-rebuild-base`

**File**: `bin/preview-rebuild-base` (executable)

```bash
#!/usr/bin/env bash
# Build the preview base image. Run after Gemfile changes in lib/preview/skeleton/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUBY_VERSION="$(cat "$REPO_ROOT/.ruby-version" | sed 's/^ruby-//')"

docker build \
  -t preview-base:latest \
  --build-arg RUBY_VERSION="$RUBY_VERSION" \
  -f "$REPO_ROOT/lib/preview/Dockerfile.base" \
  "$REPO_ROOT/lib/preview"

echo "Base image rebuilt. Verify: docker images preview-base"
```

#### 4. Network bootstrap

The internal Docker network is created lazily by `PreviewManager.ensure_network!` (Step 4). No script needed here.

### Success Criteria

#### Automated:
- [ ] All three files (`Dockerfile`, `Dockerfile.base`, `bin/preview-rebuild-base`) checked in and `chmod +x` where applicable.
- [ ] `bundle exec rails test` still green (no Ruby changes that affect tests).

#### Manual:

- [ ] **`--internal` + port-publish smoke test (run FIRST)** — confirm that port-publish works on a Docker `--internal` network on YOUR setup. Docker Desktop on macOS/Windows uses vpnkit/qemu rather than native iptables and has occasionally had edge cases here.

  ```bash
  docker network create --internal test-internal-net 2>/dev/null || true
  docker run --rm -d --name test-internal --network test-internal-net -p 4444:80 nginx:alpine
  sleep 2
  curl -fsS http://localhost:4444/ >/dev/null && echo OK || echo FAIL
  docker rm -f test-internal
  docker network rm test-internal-net
  ```

  Expect `OK`. If `FAIL`, apply the fallback below before continuing.

  **Fallback if `--internal` blocks `-p`**: drop `--internal` from network creation. In `Preview::PreviewManager.ensure_network!` (Step 4), change:
  - From: `runner.run("docker", "network", "create", "--internal", NETWORK)`
  - To:   `runner.run("docker", "network", "create", NETWORK)`

  Cost: preview containers gain outbound internet access. For PoC on a single dev laptop with no live API keys mounted into the preview, this is acceptable. **Phase 4 will reintroduce strict egress isolation** via dedicated subnet + iptables. Add a note to "What We're NOT Doing" if the fallback is taken.

- [ ] `bin/preview-rebuild-base` succeeds locally; `docker images preview-base` shows the image; size < 1.5 GB.
- [ ] Pick an existing workspace (`~/projects/rails-app-generator-workspaces/project_38/`) and manually build a per-project image: `docker build -t preview-test -f lib/preview/Dockerfile ~/projects/rails-app-generator-workspaces/project_38`. Verify success and that build time < 60 s.
- [ ] `docker run --rm -p 3038:3000 preview-test` boots; `curl http://localhost:3038/up` returns 200. Stop with Ctrl-C.

**Pause for manual confirmation. The base image build is the riskiest single step (gem versions, Ruby version, etc.). Confirm before continuing.**

---

## Step 4: `PreviewManager`

### Commit
`phase 3 step 4: lib/preview/preview_manager.rb (start/stop/cleanup)`

### Overview
Plain Ruby class that orchestrates `docker build`, `docker run`, healthcheck, and cleanup. Idempotent `start`. Uses an injectable `runner` so unit tests can stub the shell layer (mirrors `ExecuteInstructionJob#run_roast_subprocess` pattern).

### Changes Required

#### 1. `lib/preview/preview_manager.rb`

**File**: `lib/preview/preview_manager.rb`

Note: `SystemRunner` lives in its own file (`lib/preview/system_runner.rb`, see below). Zeitwerk's `autoload_lib` requires one top-level constant per file — putting `Preview::PreviewManager` and `Preview::SystemRunner` in the same file would fail `bundle exec rails zeitwerk:check` (and production eager_load).

```ruby
require "shellwords"

module Preview
  class PreviewManager
    MEMORY_LIMIT = "512m"
    CPU_LIMIT    = "0.5"
    PIDS_LIMIT   = 100
    NETWORK      = "preview-internal"
    BASE_TAG     = "preview-base:latest"
    BUILD_TIMEOUT_SECONDS  = 8 * 60
    HEALTH_TIMEOUT_SECONDS = 60
    HEALTH_INTERVAL_SECONDS = 1
    ERROR_TRUNCATE = 2_000

    Result = Struct.new(:ok, :stdout, :stderr, :exit_code, keyword_init: true)

    def initialize(runner: SystemRunner.new)
      @runner = runner
    end

    # Idempotent. If a preview exists for this project, stop it first.
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

      project.update!(preview_state: :running)
      ActiveSupport::Notifications.instrument(
        "preview.ready",
        project_id: project.id, url: project.preview_url
      )
      broadcast(project)
    rescue => e
      handle_failure(project, e)
    end

    def stop(project)
      cid = project.preview_container_id
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

    def self.ensure_network!(runner: SystemRunner.new)
      result = runner.run("docker", "network", "inspect", NETWORK, capture: true)
      return if result.ok
      runner.run("docker", "network", "create", "--internal", NETWORK)
    end

    def ensure_network! = self.class.ensure_network!(runner: @runner)

    # Boot-time recovery. The Rails process may have been killed while a
    # preview was running; the DB row says :running but the container is
    # detached from any Ruby supervisor. Force-stop any preview-* containers
    # and reset rows so the UI shows truth.
    #
    # Wrapped in rescue so a missing Docker (CI, fresh machine) does not
    # crash boot for non-preview workflows.
    #
    # Filter strategy: `docker ps --filter name=...` does substring matching
    # by default, and regex-anchor support varies across engine versions —
    # `name=^preview-` is unreliable. Instead list everything and prefix-match
    # in Ruby against `{{.Names}}` output (one name per line).
    PREVIEW_CONTAINER_PREFIX = "preview-"
    private_constant :PREVIEW_CONTAINER_PREFIX

    def self.reset_orphans!(runner: SystemRunner.new)
      list = runner.run("docker", "ps", "-a", "--format", "{{.Names}}", capture: true)
      names = list.ok ? list.stdout.split("\n").map(&:strip).reject(&:empty?) : []
      orphans = names.select { |n| n.start_with?(PREVIEW_CONTAINER_PREFIX) }
      orphans.each { |name| runner.run("docker", "rm", "-f", name) }

      Project.where(preview_state: %i[starting running]).find_each do |project|
        project.update!(
          preview_state: :stopped,
          preview_container_id: nil,
          preview_started_at: nil,
          preview_error: "Reset on boot — process restarted while preview was running"
        )
      end
    rescue => e
      Rails.logger.error("[PreviewManager.reset_orphans!] #{e.class}: #{e.message}")
    end

    private

    # Single tag per project; Docker layer cache invalidates on COPY content
    # hash, so a stable tag is fine. `:latest` is overwritten on each rebuild.
    def project_tag(project)
      "preview-#{project.id}:latest"
    end

    def build_image(project)
      tag = project_tag(project)
      result = @runner.run(
        "docker", "build",
        "-t", tag,
        "--build-arg", "BASE_TAG=#{BASE_TAG}",
        "-f", Rails.root.join("lib/preview/Dockerfile").to_s,
        project.workspace_path,
        capture: true,
        timeout: BUILD_TIMEOUT_SECONDS
      )
      raise BuildError, result.stderr unless result.ok
      tag
    end

    def run_container(project, tag)
      port = project.preview_port
      result = @runner.run(
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
        "-p", "#{port}:3000",
        "-v", "#{File.join(project.workspace_path, 'db')}:/app/db",
        "-e", "RAILS_LOG_TO_STDOUT=1",
        tag,
        capture: true
      )
      raise RunError, result.stderr unless result.ok
      result.stdout.strip
    end

    def health_check!(project)
      url = "http://localhost:#{project.preview_port}/up"
      deadline = Time.current + HEALTH_TIMEOUT_SECONDS
      loop do
        return if curl_ok?(url)
        raise HealthcheckTimeout, "no /up after #{HEALTH_TIMEOUT_SECONDS}s" if Time.current > deadline
        sleep HEALTH_INTERVAL_SECONDS
      end
    end

    def curl_ok?(url)
      result = @runner.run("curl", "-fsS", "-o", "/dev/null", "-m", "2", url, capture: true)
      result.ok
    end

    def handle_failure(project, error)
      Rails.logger.error("[PreviewManager] #{error.class}: #{error.message}")
      cid = project.preview_container_id
      @runner.run("docker", "rm", "-f", cid) if cid.present?
      @runner.run("docker", "image", "rm", "-f", project_tag(project))
      project.update!(
        preview_state: :failed,
        preview_container_id: nil,
        preview_error: error.message.to_s.first(ERROR_TRUNCATE)
      )
      broadcast(project)
    end

    def broadcast(project)
      Turbo::StreamsChannel.broadcast_replace_to(
        project,
        target: "preview",
        partial: "previews/pane",
        locals: { project: project }
      )
    end

    class BuildError < StandardError; end
    class RunError < StandardError; end
    class HealthcheckTimeout < StandardError; end
  end
end
```

#### 2. `lib/preview/system_runner.rb`

**File**: `lib/preview/system_runner.rb`

```ruby
require "open3"

module Preview
  class SystemRunner
    Result = PreviewManager::Result

    def run(*cmd, capture: false, timeout: nil)
      if capture
        out, err, status = Open3.capture3(*cmd)
        Result.new(ok: status.success?, stdout: out, stderr: err, exit_code: status.exitstatus)
      else
        ok = system(*cmd)
        Result.new(ok: ok, stdout: "", stderr: "", exit_code: $?.exitstatus)
      end
    end
  end
end
```

(Note: `timeout` param in `run` is documented but not enforced in the simple `Open3` path; for PoC, rely on Docker's own behavior + healthcheck timeout. Add real timeout support if needed.)

#### 3. Autoload `lib/preview/`

No config change needed — `config/application.rb` already has `config.autoload_lib(ignore: %w[assets tasks])`, which covers `lib/preview/`. Both `Preview::PreviewManager` and `Preview::SystemRunner` resolve automatically (one constant per file is what Zeitwerk requires). Verify with `bundle exec rails zeitwerk:check` and `rails runner 'Preview::PreviewManager; Preview::SystemRunner'`.

#### 4. Boot-time orphan reset

**File**: `config/initializers/preview_reset.rb` (new)

```ruby
# When the Rails process is killed mid-preview, the docker container outlives
# the supervisor. On next boot we reconcile: kill stray preview-* containers
# and flip any :starting / :running rows to :stopped with an error marker so
# the user sees the divergence rather than a phantom "running" pill.
Rails.application.config.after_initialize do
  next if Rails.env.test?
  # Only run during real server / runner / console boots — not migrations,
  # asset precompile, etc. (which load the env but don't serve previews).
  command = ARGV.first.to_s
  next unless %w[server runner console s c].include?(command) || ENV["BIN_DEV"] == "1"

  Preview::PreviewManager.reset_orphans!
end
```

(Gated to avoid running during `rails db:migrate`, `rails assets:precompile`, etc. — the simplest reliable signal is the rails CLI command name. `bin/dev` sets no env by default; if needed, add `ENV["BIN_DEV"]=1` at the top of `bin/dev` — TODO confirm during Step 4 manual verification.)

#### 5. Tests

**File**: `test/lib/preview/preview_manager_test.rb` (new — `mkdir -p test/lib/preview` first; Rails Minitest globs `test/**/*_test.rb` so any depth works)

Use a fake runner that records `run` calls and returns scripted results. Test cases (one per branch, per memory `feedback_test_branch_coverage.md`):

- Happy path: `start(project)` → state transitions stopped → starting → running, container_id set, `preview.ready` instrumented, broadcast called.
- Build failure: docker build returns non-zero → state=failed, error stored, image cleaned up.
- Run failure: docker build OK but docker run fails → state=failed, image cleaned up.
- Healthcheck timeout: build+run OK but curl never succeeds → state=failed, container removed.
- `start` with existing container: stop is called first, then full cycle.
- `stop` with no container_id: no-op except state reset.
- `stop` removes container + image + clears columns.
- `ensure_network!` is idempotent (no error if network exists).
- `reset_orphans!` with stale `:running` row + ghost `preview-N` container: container is `docker rm -f`'d, row flips to `:stopped` with `preview_error` set to the boot-reset marker.
- `reset_orphans!` when `docker` command is unavailable: rescues, logs, does NOT raise (boot must not crash).

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test test/lib/preview/preview_manager_test.rb` green.
- [ ] `bundle exec rails test` full suite green.
- [ ] `bundle exec rails zeitwerk:check` green (verifies both `lib/preview/preview_manager.rb` and `lib/preview/system_runner.rb` define exactly the expected constants).
- [ ] Both `Preview::PreviewManager` and `Preview::SystemRunner` resolve in `rails runner` without explicit `require`.

#### Manual:
- [ ] In `rails c`: `Preview::PreviewManager.new.start(Project.find(38))`. Wait. Verify `project_38.preview_state == "running"`, `docker ps` shows `preview-38`, `curl http://localhost:3038/up` returns 200.
- [ ] `Preview::PreviewManager.new.stop(Project.find(38))`. Verify `docker ps` does NOT show `preview-38`, columns cleared.
- [ ] Force a failure: stop the test container, set `project.preview_container_id = "fake"`, call `start` — verify it cleans up gracefully and ends in `:running`.
- [ ] **Orphan reset**: start a preview via `start(...)`, then `Ctrl-C` `bin/dev` (don't call `stop`). Confirm `docker ps` still shows `preview-38`. Restart `bin/dev`. Watch logs: `[PreviewManager.reset_orphans!]` activity (or success silently). Verify `docker ps` no longer shows `preview-38`, project's `preview_state == "stopped"`, `preview_error` contains "Reset on boot".

**Pause for manual confirmation. This is the core security-boundary validation point.**

---

## Step 5: Jobs + `:preview` queue

### Commit
`phase 3 step 5: StartPreviewJob, StopPreviewJob, :preview queue`

### Overview
Thin job wrappers around `PreviewManager`. New `:preview` queue with concurrency 1.

### Changes Required

#### 1. Jobs

**File**: `app/jobs/start_preview_job.rb`

```ruby
class StartPreviewJob < ApplicationJob
  queue_as :preview

  def perform(project_id)
    project = Project.find(project_id)
    Preview::PreviewManager.new.start(project)
  end
end
```

**File**: `app/jobs/stop_preview_job.rb`

```ruby
class StopPreviewJob < ApplicationJob
  queue_as :preview

  def perform(project_id)
    project = Project.find(project_id)
    Preview::PreviewManager.new.stop(project)
  end
end
```

#### 2. Queue config

**File**: `config/queue.yml`

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: [generation]
      threads: 1
      processes: 1
      polling_interval: 1
    - queues: [preview]
      threads: 1
      processes: 1
      polling_interval: 1
    - queues: [default, mailers]
      threads: 3
      processes: <%= ENV.fetch("JOB_CONCURRENCY", 1) %>
      polling_interval: 0.1
```

#### 3. Tests

**File**: `test/jobs/start_preview_job_test.rb`, `test/jobs/stop_preview_job_test.rb`

- Each job calls `PreviewManager#start` / `#stop` with the right project. Stub `PreviewManager` (via `Preview::PreviewManager.stub(:new, fake)`).
- Each job uses `:preview` queue.

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test test/jobs/start_preview_job_test.rb test/jobs/stop_preview_job_test.rb` green.
- [ ] `bundle exec rails test` full suite green.

#### Manual:
- [ ] Start `bin/dev`. `StartPreviewJob.perform_later(38)`; observe Solid Queue worker log lines tagged `[ActiveJob] [StartPreviewJob]`. Wait, verify container.
- [ ] `StopPreviewJob.perform_later(38)`; verify container stops.

---

## Step 6: Wiring + UI (controller, routes, partials, layout split, event subscriber)

### Commit
`phase 3 step 6: PreviewsController + previews UI + auto-stop on instruction.requested`

### Overview
End-to-end wiring. The largest commit; if review feedback says split, split into 6a (controller + routes + subscriber) and 6b (UI partials + layout).

### Changes Required

#### 1. Routes

**File**: `config/routes.rb`

```ruby
resources :projects, only: [:new, :create, :show] do
  resources :messages, only: [:create]
  resource  :preview,  only: [:create, :destroy]
end
```

This produces `project_preview_path(@project)` for both create (POST) and destroy (DELETE).

#### 2. `PreviewsController`

**File**: `app/controllers/previews_controller.rb`

```ruby
class PreviewsController < ApplicationController
  before_action :load_project

  def create
    # Guard: only allow start from terminal states. Prevents double-click /
    # stale-tab races that would result in `docker run --name preview-N` losing
    # to "name already in use" on the second attempt.
    unless @project.preview_state.in?(%w[stopped failed])
      return head :conflict
    end

    @project.update!(preview_state: :starting, preview_error: nil)
    StartPreviewJob.perform_later(@project.id)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("preview", partial: "previews/pane", locals: { project: @project }) }
      format.html { redirect_to @project }
    end
  end

  def destroy
    StopPreviewJob.perform_later(@project.id)
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("preview", partial: "previews/pane", locals: { project: @project }) }
      format.html { redirect_to @project }
    end
  end

  private

  def load_project
    @project = Project.find(params[:project_id])
  end
end
```

Note: `create` flips state to `:starting` synchronously so the UI updates immediately on the form submit; the job picks it up and either completes (state → :running) or fails (state → :failed) shortly after. The guard above means a re-POST while already `:starting` or `:running` returns 409 Conflict — the user's existing in-flight start is preserved.

#### 3. Helper

**File**: `app/helpers/previews_helper.rb`

```ruby
module PreviewsHelper
  def preview_pane_partial(project)
    case project.preview_state.to_sym
    when :stopped, nil then "previews/stopped"
    when :starting     then "previews/starting"
    when :running      then "previews/running"
    when :failed       then "previews/failed"
    end
  end
end
```

(Per memory `feedback_no_logic_in_views.md` — branching lives in the helper.)

#### 4. Partials

**File**: `app/views/previews/_pane.html.erb`

```erb
<div id="preview" class="border rounded p-4 bg-white">
  <%= render preview_pane_partial(project), project: project %>
</div>
```

**File**: `app/views/previews/_stopped.html.erb`

```erb
<div class="flex flex-col items-center justify-center h-full text-gray-500">
  <p class="mb-4">No preview running.</p>
  <%= button_to "▶ Start preview", project_preview_path(project),
        method: :post, class: "px-4 py-2 bg-blue-600 text-white rounded" %>
</div>
```

**File**: `app/views/previews/_starting.html.erb`

```erb
<div class="flex flex-col items-center justify-center h-full text-gray-500">
  <p class="mb-2">⏳ Starting preview…</p>
  <p class="text-sm">10-30 s typical (longer on first build).</p>
</div>
```

**File**: `app/views/previews/_running.html.erb`

```erb
<div class="flex flex-col gap-2">
  <div class="flex items-center justify-between">
    <a href="<%= project.preview_url %>" target="_blank" class="text-sm text-blue-600 underline">
      <%= project.preview_url %> ↗
    </a>
    <%= button_to "⏹ Stop", project_preview_path(project),
          method: :delete, class: "px-3 py-1 text-sm bg-gray-200 rounded" %>
  </div>
  <iframe
    src="<%= project.preview_url %>"
    class="w-full h-[600px] border rounded"
    sandbox="allow-same-origin allow-scripts allow-forms"></iframe>
</div>
```

**File**: `app/views/previews/_failed.html.erb`

```erb
<div class="flex flex-col gap-2">
  <p class="text-red-700">❌ Preview failed.</p>
  <% if project.preview_error.present? %>
    <pre class="text-xs bg-gray-100 p-2 rounded overflow-auto max-h-40"><%= project.preview_error %></pre>
  <% end %>
  <%= button_to "↻ Retry", project_preview_path(project),
        method: :post, class: "px-4 py-2 bg-blue-600 text-white rounded self-start" %>
</div>
```

#### 5. Layout split

**File**: `app/views/projects/show.html.erb`

```erb
<section class="w-full max-w-7xl mx-auto px-4">
  <%= turbo_stream_from @project %>

  <h1 class="text-2xl font-semibold mb-4"><%= @project.name %></h1>

  <div class="grid lg:grid-cols-2 gap-6">
    <div class="flex flex-col">
      <div id="active_revisions">
        <%= render "revisions/list", revisions: @active_revisions %>
      </div>
      <div id="messages" class="flex flex-col gap-3 mb-6">
        <%= render partial: "messages/message", collection: @messages, as: :message %>
      </div>
      <%= render "suggestions/frame", prompts: [] %>
      <% if flash[:alert] %>
        <div class="mb-4 text-red-700"><%= flash[:alert] %></div>
      <% end %>
      <%= render "messages/form", project: @project %>
    </div>

    <div class="lg:sticky lg:top-4 lg:h-fit">
      <%= render "previews/pane", project: @project %>
    </div>
  </div>
</section>
```

#### 6. Event subscriber for auto-stop

**File**: `config/initializers/event_subscribers.rb` — append:

```ruby
ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  StopPreviewJob.perform_later(instruction.project.id)
end
```

(Adds to the existing `instruction.requested` subscribers — order in the file: ExecuteInstructionJob enqueue, broadcast active revisions, **stop preview**.)

#### 7. Tests

**File**: `test/controllers/previews_controller_test.rb`

- `POST /projects/:id/preview` from `:stopped` enqueues `StartPreviewJob` with the right id, sets state to `:starting`, returns turbo_stream.
- `POST /projects/:id/preview` from `:failed` also enqueues + flips to `:starting` (retry path).
- `POST /projects/:id/preview` from `:starting` returns 409 Conflict, does NOT enqueue another job (double-click guard).
- `POST /projects/:id/preview` from `:running` returns 409 Conflict (must Stop first).
- `DELETE /projects/:id/preview` enqueues `StopPreviewJob`, returns turbo_stream.
- 404 for unknown project_id.

**File**: `test/helpers/previews_helper_test.rb`

- One assertion per state → partial mapping.

**File**: `test/integration/preview_subscriber_test.rb` (new — placement chosen because integration test class loads initializers cleanly)

- `ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: ...)` causes `StopPreviewJob` to be enqueued for the project. Use `assert_enqueued_with(job: StopPreviewJob, args: [project.id])`.
- Existing subscribers are not regressed: `ExecuteInstructionJob` is also enqueued; revisions broadcast still fires.

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test` full suite green.
- [ ] `assert_enqueued_with(job: StartPreviewJob, args: [project.id])` passes from controller test.
- [ ] All 4 partials present in `app/views/previews/`.

#### Manual:
- [ ] Open project 38 in browser. Layout is split: chat left, preview pane right with "▶ Start preview" button.
- [ ] Click Start. Pane flips to "⏳ Starting preview…". After 10-30 s, iframe appears with the todo-list app.
- [ ] Click around inside the iframe — clicks work, forms submit, the app responds. (CSRF + cookies in `allow-same-origin` sandbox.)
- [ ] Click Stop. Pane returns to "Start preview" state. `docker ps` shows no `preview-38`.
- [ ] Trigger a new generation (chat message). Preview pane auto-flips to `:stopped` (StopPreviewJob fires from `instruction.requested`).
- [ ] Force a failure: `docker rmi preview-base:latest` (so build will fail), click Start. Pane shows "❌ Preview failed" with stderr in `<pre>`. Click Retry — repeats and fails again. Restore base image, Retry succeeds.

**Pause for manual confirmation.**

---

## Step 7: `CleanupIdlePreviewsJob`

### Commit
`phase 3 step 7: CleanupIdlePreviewsJob recurring every 5 min`

### Overview
Recurring job that stops previews running for >30 min. Solid Queue's `recurring.yml`.

### Changes Required

#### 1. Job

**File**: `app/jobs/cleanup_idle_previews_job.rb`

```ruby
class CleanupIdlePreviewsJob < ApplicationJob
  queue_as :preview

  # PoC interpretation: "idle" = "running for >30 min", regardless of last
  # access. We don't track iframe activity yet; revisit if users complain
  # about active previews getting reaped.
  IDLE_TIMEOUT = 30.minutes

  def perform
    Project.where(preview_state: :running)
           .where("preview_started_at < ?", IDLE_TIMEOUT.ago)
           .find_each { |project| StopPreviewJob.perform_later(project.id) }
  end
end
```

#### 2. Recurring config

**File**: `config/recurring.yml` — add to **all environments** (so dev cleanup works), not just production:

```yaml
default: &default
  cleanup_idle_previews:
    class: CleanupIdlePreviewsJob
    queue: preview
    schedule: every 5 minutes

development:
  <<: *default

production:
  <<: *default
  clear_solid_queue_finished_jobs:
    command: "SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)"
    schedule: every hour at minute 12
```

(Keep the existing `clear_solid_queue_finished_jobs` in production-only.)

#### 3. Tests

**File**: `test/jobs/cleanup_idle_previews_job_test.rb`

- Project with `preview_started_at` > 30 min ago AND `preview_state == :running` → enqueues `StopPreviewJob`.
- Project with `preview_started_at` < 30 min ago → no enqueue.
- Project with `preview_state == :stopped` regardless of `preview_started_at` → no enqueue.

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test test/jobs/cleanup_idle_previews_job_test.rb` green.
- [ ] `bundle exec rails test` full suite green.

#### Manual:
- [ ] Start preview, then in `rails c` set `Project.find(38).update!(preview_started_at: 31.minutes.ago)`. Wait up to 5 min (or trigger manually `CleanupIdlePreviewsJob.perform_now`). Verify container stops.

---

## Step 8: Gated E2E integration test

### Commit
`phase 3 step 8: E2E_PREVIEW=1 preview_lifecycle integration test`

### Overview
A test that exercises the full Docker chain: skeleton workspace → real `docker build` → `docker run` → curl `/up` → `docker rm`. Mirrors `E2E_GENERATE=1` from Phase 2 Step 7.

### Changes Required

#### 1. Test

**File**: `test/integration/preview_lifecycle_test.rb`

```ruby
require "test_helper"

class PreviewLifecycleTest < ActionDispatch::IntegrationTest
  WALL_TIME_BUDGET = 180  # seconds — base image already built; per-project build + run + curl

  setup do
    skip "set E2E_PREVIEW=1 to enable" unless ENV["E2E_PREVIEW"] == "1"
    @workspace_root = Dir.mktmpdir("rails-app-generator-preview-test-")
    ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] = @workspace_root
    @project = Project.create!(name: "preview_test_#{Time.now.to_i}")
    seed_workspace_from_skeleton(@project.workspace_path)
  end

  teardown do
    Preview::PreviewManager.new.stop(@project) rescue nil
    FileUtils.rm_rf(@workspace_root) if @workspace_root
    ENV.delete("RAILS_APP_GENERATOR_WORKSPACE_ROOT")
  end

  test "full lifecycle: build, run, healthcheck, stop" do
    assert_in_wall_time(WALL_TIME_BUDGET) do
      Preview::PreviewManager.new.start(@project)
    end

    @project.reload
    assert_equal "running", @project.preview_state
    assert @project.preview_container_id.present?

    # Real HTTP healthcheck against the running container.
    ok = system("curl", "-fsS", "-o", "/dev/null",
                "http://localhost:#{@project.preview_port}/up")
    assert ok, "preview /up did not respond 2xx"

    Preview::PreviewManager.new.stop(@project)
    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_nil @project.preview_container_id
  end

  private

  def seed_workspace_from_skeleton(workspace)
    FileUtils.mkdir_p(File.dirname(workspace))
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton')}/.",         workspace)
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton-overlay')}/.", workspace)
    Bundler.with_unbundled_env do
      ok = system("cd #{Shellwords.escape(workspace)} && bundle install --jobs 4 --quiet")
      raise "bundle install failed in test setup" unless ok
      ok = system("cd #{Shellwords.escape(workspace)} && git init -q && git add -A && " \
                  "git -c user.email=t@t -c user.name=t commit -q -m 'seed'")
      raise "git init failed in test setup" unless ok
    end
  end

  def assert_in_wall_time(budget_seconds)
    started = Time.current
    yield
    elapsed = Time.current - started
    assert elapsed < budget_seconds, "exceeded #{budget_seconds}s budget: #{elapsed.round(1)}s"
  end
end
```

#### 2. Test runs

The test requires the base image to be built first (`bin/preview-rebuild-base`). Document this in the test setup comment.

### Success Criteria

#### Automated:
- [ ] `bundle exec rails test test/integration/preview_lifecycle_test.rb` (no env) → all tests skip with "set E2E_PREVIEW=1 to enable".
- [ ] `E2E_PREVIEW=1 bundle exec rails test test/integration/preview_lifecycle_test.rb` → green; wall time < 180 s on a warm Docker layer cache.
- [ ] After the test runs, `docker ps -a | grep preview-` shows nothing (cleanup worked).

#### Manual:
- [ ] Run the test once with the base image absent (`docker rmi preview-base:latest && E2E_PREVIEW=1 ...`) — should fail loudly with a docker build error referencing `preview-base:latest`. Restore base image, re-run, green.

---

## Step 9: Canon + status + README updates

### Commit
`phase 3 step 9: docs — W3 implementation note, vision Step 5, tech stack, README, CLAUDE.md status`

### Overview
Bring canon docs + `CLAUDE.md` status + project README in sync with what's been built.

### Changes Required

#### 1. `docs/02-architecture/01-workflows-and-decisions.md` — annotate W3

After line 150 (the "W3 is fully deterministic" sentence), add:

```markdown
**Implementation**: W3 is implemented as a plain Ruby class (`lib/preview/preview_manager.rb`), not a Roast workflow — every step is deterministic and Roast's value (LLM/agent integration) does not apply. The class is invoked from `StartPreviewJob` / `StopPreviewJob`.

**Trigger model in Phase 3**: `start` is user-initiated (button click → `PreviewsController#create`); `stop` is user-initiated OR auto-fired by the `instruction.requested` subscriber (because production-mode containers don't autoload — a running preview shows stale code mid-generation regardless). The `instruction.completed` subscriber does NOT auto-start; preview is a deliberate user-driven feature.
```

#### 2. `docs/01-vision/02-user-journey.md` — Step 5 (Preview)

Update Step 5's "Server" sub-section: replace the `rails server` mention with "Docker container with hardened flags (no caps, read-only, internal network, memory/CPU/pids capped); iframe `src` is `http://localhost:#{3000 + project.id}` in Phase 3 PoC, `https://#{id}.preview.<domain>` in Phase 4."

Note that the iframe is `sandbox="allow-same-origin allow-scripts allow-forms"`.

Update the "Listed problems" section: mark "isolation" and "security" as **solved in Phase 3** for the local PoC; "seed data" remains a deferred concern.

#### 3. `docs/02-architecture/03-tech-stack.md` — generator stack

Add to "Our application's stack (generator)" (around line 175):

- **Docker** — required on the host for preview containers. Generator shells `docker build`, `docker run`, `docker network`, `docker port` via `Preview::PreviewManager`.
- (Phase 4 will add: kamal-proxy for routing.)

#### 4. `CLAUDE.md` — status update

Update the Phase 3 status line: `Phase 3 (preview isolation via Kamal + Docker): **closed** at the local-PoC level. End-to-end demo on project 38: button-driven start/stop, hardened Docker container, iframe in side-by-side layout. E2E test gated by E2E_PREVIEW=1. Phase 4 (production deploy on Hetzner/DO with kamal-proxy + DNS + wildcard cert) is the next candidate.`

Add `docs/03-plans/02-phase-3-preview-isolation.md` (analysis) and `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` (this plan) to "Reading order when resuming" before the canon.

Add to `Conventions`:

- **Preview infrastructure**: `lib/preview/preview_manager.rb` (Ruby) drives Docker. `lib/preview/Dockerfile{,.base}` are owned by this repo — never read from generated apps. The skeleton at `lib/preview/skeleton/` is the canonical fresh-Rails-app baseline; regenerate with `bin/preview-regen-skeleton` when bumping Rails. Rebuild the base image with `bin/preview-rebuild-base` after Gemfile changes.

#### 5. README — preview operations

**File**: `README.md` — add a "Running previews locally" section near the existing user-manual content. Cover:

- Docker is required on the host. Verify with `docker --version`.
- One-time setup: `bin/preview-rebuild-base` (builds the `preview-base:latest` image, ~2-4 min on a clean Docker).
- Re-run `bin/preview-rebuild-base` after any change to `lib/preview/skeleton/Gemfile`.
- Re-run `bin/preview-regen-skeleton` to bump Rails (rare).
- In the UI: click "▶ Start preview" on a project page; iframe loads at `http://localhost:#{3000 + project.id}` after build + boot.
- Idle previews auto-stop after 30 min.
- Troubleshooting: `docker logs preview-<id>` for in-container logs; `docker ps --filter name=preview-` to list.

#### 6. Memory updates

- Update memory `project_verify_no_system_tests.md` — note that Phase 3 did NOT introduce headless-Chrome tests; preview is verified via host-side `curl /up` and a gated E2E test that doesn't rely on a browser. Concern remains for any future feature requiring real browser automation.

### Success Criteria

#### Automated:
- [ ] `git grep "Phase 3.*analysis ready"` returns nothing (status updated).
- [ ] `git grep "lib/preview/preview_manager"` finds references in W3 canon, tech stack, CLAUDE.md.
- [ ] `bundle exec rails test` still green (no code changes).

#### Manual:
- [ ] Re-read the updated W3 section + Vision Step 5 — accurately describe what shipped.
- [ ] CLAUDE.md status line correctly reflects current state.

---

## Testing Strategy

### Unit Tests (per phase)
- `Project` model — preview_url, preview_port, enum predicates.
- `Preview::PreviewManager` — happy path + each failure branch (build, run, healthcheck, stop, idempotent start).
- `StartPreviewJob`, `StopPreviewJob`, `CleanupIdlePreviewsJob` — enqueue + delegation.
- `PreviewsController` — POST/DELETE behaviors, 404, turbo_stream response.
- `PreviewsHelper` — state → partial mapping.
- Event subscriber — `instruction.requested` triggers `StopPreviewJob`.

### Integration Tests
- `test/integration/preview_lifecycle_test.rb` (gated E2E_PREVIEW=1) — full Docker chain on a tmpdir workspace seeded from the skeleton.
- `test/integration/generate_todo_list_test.rb` (existing E2E_GENERATE=1) — must stay green; wall-time should improve from skeleton refactor.

### Manual Testing
- Each step has a manual-verification gate. The Step 6 demo (chat + iframe + click around in the generated todo-list app, hardened by docker flags) is the headline demo.
- After Step 7: leave a preview running, force `preview_started_at = 31.minutes.ago`, observe auto-cleanup.

## Performance Considerations

- **First per-project build (cold base image not present)**: 2-4 min (apt + bundle for the skeleton). One-time per Ruby/Rails bump.
- **Per-project build (warm base image)**: 10-30 s — only new gems + tailwindcss build.
- **Container boot to /up healthy**: 5-15 s for a typical generated app in dev mode.
- **Healthcheck timeout**: 60 s — gives margin for slow initial autoload.
- **Memory budget per preview**: 512 MB hard limit. Generator + 5 active previews ≈ 3 GB RAM (acceptable on a dev laptop with 16 GB+).
- **Build cache**: rely on Docker's layer cache. No CI integration in Phase 3.

## Migration Notes

- **Existing workspaces** (e.g., `~/projects/rails-app-generator-workspaces/project_38/`) were created by the old `rails new`-based flow. They have `module Project38` (or similar) in `config/application.rb`, NOT `module RailsApplication`. Step 1 doesn't migrate these — they keep working as-is for Phase 2 generation.
- **Preview won't work on workspaces with non-`RailsApplication` module names** if the Dockerfile has any `RailsApplication`-specific assumption (it doesn't currently — the Dockerfile is module-name-agnostic). Verify during Step 6 manual testing on project 38.
- **First-time-on-new-machine setup** is documented in Step 9's README updates: install Docker, then `bin/preview-rebuild-base`.
- **Existing workspaces also lack `bin/preview-entrypoint`** (overlay didn't exist when they were created). Workaround for testing on project 38 specifically: `cp lib/preview/skeleton-overlay/bin/preview-entrypoint ~/projects/rails-app-generator-workspaces/project_38/bin/` once. Or wipe + regenerate via a fresh test instruction.

## References

- Phase 3 analysis: `docs/03-plans/02-phase-3-preview-isolation.md`
- Kickoff research: `thoughts/shared/research/2026-04-26/phase-3-preview-isolation-kickoff.md`
- Phase 2 plan (precedent for Phase 2 wall-time budget, subprocess pattern): `docs/03-plans/01-phase-2-poc-generator-app.md`
- W3 canon definition: `docs/02-architecture/01-workflows-and-decisions.md:137-150`
- Preview event taxonomy: `docs/02-architecture/02-layer-integration.md:50-52`
- `preview.ready` subscriber rule: `docs/02-architecture/02-layer-integration.md:182-189`
- Vision Step 5: `docs/01-vision/02-user-journey.md:417-432`
- Security motivation: `spikes/roast/findings.md:96-111`, `:209`
- Pattern precedent (subprocess + injectable runner): `app/jobs/execute_instruction_job.rb:126`
- Pattern precedent (gated E2E test): `test/integration/generate_todo_list_test.rb`
