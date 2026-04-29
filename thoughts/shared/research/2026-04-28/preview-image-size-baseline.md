---
date: 2026-04-28T19:19:35+0200
researcher: Paweł Strzałkowski
git_commit: ccdcbdcef0642f6df34e81bfb1b0e4f9b984cd1d
branch: main
repository: rails-app-generator
topic: "Preview Docker image size — baseline knowledge for further plans"
tags: [research, docker, preview, image-size, phase-4, kamal]
status: complete
last_updated: 2026-04-28
last_updated_by: Paweł Strzałkowski
---

# Research: Preview Docker image size — baseline knowledge for further plans

**Date**: 2026-04-28T19:19:35+02:00
**Researcher**: Paweł Strzałkowski
**Git Commit**: ccdcbdcef0642f6df34e81bfb1b0e4f9b984cd1d
**Branch**: main
**Repository**: rails-app-generator

## Research Question

The size of the preview Docker image may be crucial for the next phase (Phase 4 production deploy on Hetzner). Before starting the plan at `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md`, document whether the current Dockerfile is as size-optimal as it gets — covering the base image and its capabilities, given that we only need Ruby 4.0.2 and Rails uses importmaps (no Node). Gather a knowledge baseline for further plans.

## Summary

The preview build stack consists of two Dockerfiles:

- **`lib/preview/Dockerfile.base`** — produces `preview-base:latest`, a single-stage image baked once per skeleton/Gemfile change. Currently **894 MB** on disk.
- **`lib/preview/Dockerfile`** — per-project image, `FROM preview-base`, copies the workspace, runs `bundle install` (delta over skeleton's bundle), runs `bin/rails tailwindcss:build`, exposes port 3000.

Layer-by-layer measurement of `preview-base:latest` shows the 894 MB is dominated by two layers, each ≈350 MB:

| Layer (newest → oldest) | Size | Source |
|---|---|---|
| `RUN bundle install` (skeleton's 116 gems incl. dev/test groups) | **347 MB** | `Dockerfile.base:17` |
| `COPY skeleton/Gemfile skeleton/Gemfile.lock` | 26.4 kB | `Dockerfile.base:16` |
| `RUN apt-get install build-essential libsqlite3-dev libyaml-dev curl git` | **348 MB** | `Dockerfile.base:4-6` |
| Ruby 4.0.2 install (rubygems + bundler bootstrap) | 94.9 MB | from `ruby:4.0.2-slim` |
| Initial apt update | 3.83 MB | from `ruby:4.0.2-slim` |
| Debian trixie slim base | 100 MB | from `ruby:4.0.2-slim` |
| **Total** | **894 MB** | |

Two adjacent reference Dockerfiles in the repo — the **top-level generator `Dockerfile:1-67`** and the **skeleton's `lib/preview/skeleton/Dockerfile:1-79`** — both use a multi-stage pattern that the preview-base does **not** use:

- A `base` stage with runtime-only apt deps (`curl libjemalloc2 libvips sqlite3` — no compilers, no `-dev` headers).
- A `build` stage that adds `build-essential git libvips libyaml-dev pkg-config`, runs `bundle install` with `BUNDLE_DEPLOYMENT=1` and `BUNDLE_WITHOUT="development"`, then strips `~/.bundle`, `BUNDLE_PATH/ruby/*/cache`, and `BUNDLE_PATH/ruby/*/bundler/gems/*/.git`.
- A final stage that `COPY --from=build` only the compiled bundle path and the app, without the toolchain.

The skeleton Gemfile (`lib/preview/skeleton/Gemfile:1-63`) declares 116 resolved gems including `:development` and `:test` groups (capybara, selenium-webdriver, debug, brakeman, bundler-audit, rubocop-rails-omakase, web-console). `Dockerfile.base` does not set `BUNDLE_WITHOUT`, so all of those are baked in.

Importmaps and tailwindcss-rails are confirmed Node-free: `tailwindcss-rails` ships precompiled per-platform binaries via the `tailwindcss-ruby` gem; `importmap-rails` is pure Ruby and downloads pinned JS over CDN at runtime via the browser. No `nodejs`/`yarn` package is installed in either Dockerfile or referenced in the skeleton's Gemfile.

The Phase 4 plan at `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md` adds Phase 9's pre-deploy hook that rebuilds `preview-base:latest` on the Hetzner host on every `kamal deploy` (cold ≈5 min, warm ≈25 s when Gemfile.lock is unchanged); the `lib/preview/` tree is rsynced into `/var/lib/rails-app-generator/preview-base-context/` on the host and `docker build -f Dockerfile.base` runs there. This is the only path where the base image is built in production.

## Detailed Findings

### Current preview-base build (Dockerfile.base)

**File:** `lib/preview/Dockerfile.base:1-17` (17 lines total).

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

Properties:
- **Single-stage.** Build toolchain (`build-essential`, dev headers, `git`) ships in the runtime image.
- **No `BUNDLE_WITHOUT`.** All groups install — including `:development` (capybara, selenium-webdriver are in `:test`; web-console in `:development`; debug, brakeman, bundler-audit, rubocop-rails-omakase in both).
- **No `BUNDLE_DEPLOYMENT=1`.** Lockfile compliance not enforced; not size-relevant but a reference-point delta vs the other two Dockerfiles.
- **No bundle cleanup.** `BUNDLE_PATH/ruby/X.Y.Z/cache/*.gem` and any `bundler/gems/*/.git` directories are kept in the layer.
- **No `--mount=type=cache`** for `apt` or `bundle`. Each rebuild redownloads from apt + rubygems unless the layer cache hits.
- `BUNDLE_JOBS=4 BUNDLE_RETRY=2` are speed/resilience hints; not size-relevant.

### Per-project Dockerfile

**File:** `lib/preview/Dockerfile:1-22` (22 lines total).

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

Properties:
- `COPY . .` precedes `bundle install`. Any change to any workspace file invalidates the bundle layer (cache-busting), even when the Gemfile is unchanged. Not a size delta but a build-time cost.
- `bin/rails tailwindcss:build` writes `app/assets/builds/tailwind.css` (~50 kB), which Propshaft serves under `/assets`. No Node, no `tailwindcss` npm package.
- The per-project image **inherits** every byte of `preview-base:latest` (894 MB). The only per-project delta is the workspace COPY (~20-50 MB depending on workspace state) plus any added gems.
- Multiple per-project images on the same host **share the `preview-base` layers** via Docker's union FS — the 894 MB is paid once on disk per host. The per-project deltas multiply.

### Skeleton bundle composition

**File:** `lib/preview/skeleton/Gemfile:1-63`.

Top-level (always-loaded) groups — all baked into the base layer:

- Rails 8.1.3, propshaft, sqlite3 ≥2.1, puma ≥5.0
- importmap-rails, turbo-rails, stimulus-rails, tailwindcss-rails
- tzinfo-data (windows/jruby only — pulled by rubygems but skipped at install)
- solid_cache, solid_queue, solid_cable
- bootsnap, thruster, image_processing ~> 1.2

`:development, :test` group — also baked into the base because `BUNDLE_WITHOUT` is unset:

- debug (with `irb`, `reline` deps)
- bundler-audit, brakeman, rubocop-rails-omakase

`:development` only:

- web-console

`:test` only:

- capybara, selenium-webdriver

Total: **116 unique gem specs** in `lib/preview/skeleton/Gemfile.lock` (`grep -E "^    [a-z]"` count).

Selenium-webdriver in particular pulls a chain of large native deps (websocket, ffi cross-platform binaries) that are only used by system tests, which Phase 1's `feedback project_verify_no_system_tests.md` already notes can't run in the preview environment.

The lockfile carries 10 platforms (`PLATFORMS` block in `Gemfile.lock`):

```
aarch64-linux, aarch64-linux-gnu, aarch64-linux-musl,
arm-linux-gnu, arm-linux-musl,
arm64-darwin, x86_64-darwin,
x86_64-linux, x86_64-linux-gnu, x86_64-linux-musl
```

This is the result of `bin/preview-regen-skeleton` running `bundle lock --add-platform x86_64-linux aarch64-linux` after `rails new` (the latter ships an arm64-darwin-only lockfile). All native gems with platform-specific gemspecs ship binaries for all 10 platforms in the bundled gem path (e.g., `ffi-1.17.4-aarch64-linux-gnu`, `ffi-1.17.4-aarch64-linux-musl`, `ffi-1.17.4-arm-linux-gnu`, etc. — observed in the Gemfile.lock). Bundler installs the gem matching the runtime platform; the others stay only in the cache directory if `bundle install --deployment`-equivalent path strips them.

### `.dockerignore` (build context filter)

**File:** `lib/preview/skeleton/.dockerignore:1-37`.

Excludes from build context: `.git/`, `.bundle/`, `.env*`, `config/master.key`, `config/credentials/*.key`, `log/*`, `tmp/*` (with `.keep`), `storage/*`, `node_modules/`, `app/assets/builds/*`, `public/assets`, `.devcontainer`, `.dockerignore`, `Dockerfile*`. Standard Rails 8 generator output.

Note: this `.dockerignore` lives **inside the skeleton directory** and applies to per-project image builds (where `lib/preview/Dockerfile` is the build context root, with the workspace copied in). The base-image build context is `lib/preview/` (per `bin/preview-rebuild-base`); there is no `.dockerignore` at `lib/preview/.dockerignore`, so the entire `lib/preview/` tree is sent to the daemon — including `skeleton/` (≈ skeleton's full source tree) and `skeleton-overlay/`. The skeleton's own `.dockerignore` does not apply to the base build because it sits in a subdirectory of the context root.

### `lib/preview/skeleton-overlay/`

**Files** (3 total):
- `lib/preview/skeleton-overlay/.dockerignore`
- `lib/preview/skeleton-overlay/bin/preview-entrypoint`
- `lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb`

Overlay is applied at workspace-init time (per `CLAUDE.md`), not by either Dockerfile. The overlay's `.dockerignore` (439 bytes) is a slimmer variant that supersedes the skeleton's once the workspace is materialized — this is what governs the per-project `lib/preview/Dockerfile` build context, not the skeleton's `.dockerignore`.

### Build/regen scripts

**File:** `bin/preview-rebuild-base:1-13`. Resolves Ruby version from `.ruby-version` (stripping the `ruby-` prefix per `feedback_ruby_version_prefix.md`), runs `docker build -t preview-base:latest --build-arg RUBY_VERSION=<v> -f lib/preview/Dockerfile.base lib/preview`. The build context root is `lib/preview/`.

**File:** `bin/preview-regen-skeleton:1-32`. Runs `rails new rails_application --css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci --skip-git`, rsyncs into `lib/preview/skeleton/` (excluding `.git`, `tmp/`, `log/`, `node_modules/`, `.bundle/`), strips the per-skeleton `master.key` and `credentials.yml.enc`, then `bundle lock --add-platform x86_64-linux aarch64-linux`. Run when bumping Rails minor.

### Top-level generator Dockerfile (reference comparison point #1)

**File:** `Dockerfile:1-67` (the generator's own production image, used by Kamal). 67 lines, three stages.

Stage `base` (lines 11-29):
- `FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base` — same Ruby image as preview-base.
- `apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3` — runtime-only, no compilers, no `-dev` headers.
- `ENV RAILS_ENV="production" BUNDLE_DEPLOYMENT="1" BUNDLE_PATH="/usr/local/bundle" BUNDLE_WITHOUT="development" LD_PRELOAD="/usr/local/lib/libjemalloc.so"`.

Stage `build` (lines 31-53):
- `FROM base AS build`.
- `apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config` — toolchain isolated to this throwaway stage.
- `bundle install && rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git` — bundle cache and `path:` gem `.git` dirs stripped.
- `bundle exec bootsnap precompile -j 1 --gemfile` then `bundle exec bootsnap precompile -j 1 app/ lib/`.
- `SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile`.

Stage final (lines 55-67):
- `FROM base` — discards the `build` stage including the entire toolchain.
- `groupadd ... && useradd rails ... && USER 1000:1000` — non-root.
- `COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"` — only the compiled bundle path.
- `COPY --chown=rails:rails --from=build /rails /rails` — only the app tree.
- `ENTRYPOINT ["/rails/bin/docker-entrypoint"]`, `EXPOSE 80`, `CMD ["./bin/thrust", "./bin/rails", "server"]`.

### Skeleton's Dockerfile (reference comparison point #2)

**File:** `lib/preview/skeleton/Dockerfile:1-79`. Ships with every freshly-generated workspace; identical structure to the top-level generator Dockerfile (multi-stage, `BUNDLE_DEPLOYMENT=1`, `BUNDLE_WITHOUT="development"`, cache cleanup, `USER rails`). This is the Dockerfile a generated app would use if it were deployed standalone (not as a preview).

The preview pipeline does **not** use this file. It is a sibling reference inside the build context — Rails 8 ships it via `rails new`, `bin/preview-regen-skeleton` keeps it synced, and the per-project `lib/preview/Dockerfile` ignores it (different filename — `Dockerfile.base` and `Dockerfile` at `lib/preview/`, not `lib/preview/skeleton/Dockerfile`).

### Per-image runtime needs (capabilities the base image supplies)

Items installed into `Dockerfile.base` and the role each plays at runtime in the preview container:

| Package | Purpose | Needed at runtime? |
|---|---|---|
| `build-essential` | gcc, make, libc-dev for C extensions | No — only at gem-compile time |
| `libsqlite3-dev` | SQLite headers + static libs for the `sqlite3` gem build | No — runtime needs only `libsqlite3-0` (ships transitively as a dep of the `sqlite3` apt package, which `Dockerfile.base` does not install separately; comes via dev's transitive deps) |
| `libyaml-dev` | LibYAML headers for `psych`/`yaml` gem build | No — runtime needs only `libyaml-0-2` |
| `curl` | health-check command issued by `Preview::PreviewManager#curl_ok?` (Phase 4 plan §6 changes the call to `docker exec preview-<id> curl ...`) | Yes |
| `git` | needed by Bundler when the Gemfile uses `gem ... git: ...` (skeleton's Gemfile does not, but a generated app's might) | Conditional |
| Ruby 4.0.2 (from base image) | runtime + bundler | Yes |

The `sqlite3` apt package (the runtime CLI) is **not** installed in `Dockerfile.base`. The `sqlite3` Ruby gem links against `libsqlite3-0` (pulled in transitively as a dependency of `libsqlite3-dev`); SQLite database files are read by the gem's native ext, not by the `sqlite3` CLI tool.

Compare with the top-level generator `Dockerfile:18` which installs `sqlite3` (the apt package) explicitly into the runtime stage, plus `libvips` for ActiveStorage variant generation.

### Ruby image-variant landscape (external context)

From `hub.docker.com/_/ruby` and `docker-library/ruby`:

- `ruby:4.0.2-slim-trixie` (aliased `ruby:4.0.2-slim`, default for `ARG RUBY_VERSION=4.0.2` + `-slim`): Debian trixie minimal base + Ruby 4.0.2.
- `ruby:4.0.2-alpine3.23` (aliased `ruby:4.0.2-alpine`): Alpine 3.23 + Ruby 4.0.2 built against musl libc.
- `ruby:4.0.2-slim-bookworm`: previous Debian stable variant.
- `ruby:4.0.2` (aliased plain): full Debian trixie with apt + dev tools preinstalled. Largest variant.

Reference sizes from Ruby 3.4.1 image data (no Ruby-4.0.2-specific public size table located): slim ≈ **219 MB**, alpine ≈ **99 MB**, full ≈ **1.01 GB**. Alpine is typically 45-50% smaller than slim.

Documented Alpine gotchas relevant to a Rails 8 + native-gems stack:
- musl libc vs glibc — gems like `unf_ext` and gRPC have known build/runtime breakage on musl.
- Bundler doesn't always include musl in lockfile platforms by default. The skeleton already runs `bundle lock --add-platform x86_64-linux aarch64-linux` (`bin/preview-regen-skeleton:30`), but adding `x86_64-linux-musl`/`aarch64-linux-musl` is a separate `--add-platform` call (those entries already appear in the current `Gemfile.lock` PLATFORMS block — `bundle lock` resolved them automatically because `ffi` and other gems have musl-platform gemspecs).
- Alpine uses busybox utilities (no GNU `sed`/`tail` flags etc.); a few build scripts and gem post-install hooks assume GNU.

The current `Gemfile.lock` PLATFORMS block already lists both `-musl` and `-gnu` variants for aarch64, arm, and x86_64, so a switch to alpine would not require a platform-block edit.

### Tailwind / importmap runtime requirements (external context)

Confirmed from gem READMEs (`github.com/rails/tailwindcss-rails`, `github.com/rails/importmap-rails`):

- `tailwindcss-rails` depends on `tailwindcss-ruby`, which ships **precompiled native binaries** for `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-darwin`, `arm64-darwin`, `x86_64-linux-musl`, `aarch64-linux-musl`, `x86_64-mingw`. `bin/rails tailwindcss:build` invokes the bundled binary directly; **no Node.js, no npm/yarn, no `node_modules/`** at any phase.
- `importmap-rails` is pure Ruby. Pinned packages are downloaded from JS CDNs (jspm.io, ga.jspm.io, esm.sh) **by the browser at request time**, not by the server. The server only serves the import map manifest in HTML. Vendoring (`bin/importmap pin foo --download`) ships JS files into `vendor/javascript/`, again with no Node involvement.

Net: neither gem nor any of the skeleton's gems require `nodejs`, `npm`, or `yarn` to be installed in the preview image.

### Rails 8 Dockerfile.tt template (external context)

**Source:** `github.com/rails/rails` → `railties/lib/rails/generators/rails/app/templates/Dockerfile.tt` (the upstream template that produced the skeleton's `Dockerfile`).

Two helper methods drive the apt package lists:
- `dockerfile_base_packages` (in `railties/lib/rails/generators/app_base.rb`): `curl`, database runtime package, `libvips`, `libjemalloc2`. These land in the runtime stage.
- `dockerfile_build_packages`: `build-essential`, `git`, `pkg-config`, `libyaml-dev`, database `-dev` package, optional `unzip`/`node-gyp`/`python-is-python3` (only if Node is enabled). These land in the throwaway build stage.

Defaults set by the template: `BUNDLE_DEPLOYMENT=1`, `BUNDLE_PATH=/usr/local/bundle`, `BUNDLE_WITHOUT="development"`, multi-stage build, `rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git` post-bundle, `bootsnap precompile -j 1 --gemfile`, `assets:precompile` with `SECRET_KEY_BASE_DUMMY=1`, non-root `rails:rails` user.

### BuildKit cache-mount behavior (external context)

`RUN --mount=type=cache,target=/var/cache/apt,sharing=locked` and `RUN --mount=type=cache,target=/usr/local/bundle/cache,sharing=locked` create persistent, image-layer-external directories.

Properties:
- The cached directory is **not** included in any image layer. Image size is unaffected.
- Rebuild speed: documented 8× speedup (e.g., 120 s → 15 s) on subsequent builds when only application code changes.
- Cache mounts replace the manual `rm -rf /var/lib/apt/lists/*` cleanup pattern — the apt package list never ends up in a layer in the first place.
- BuildKit must be enabled (default since Docker 20.10+).

The current `lib/preview/Dockerfile.base:4` uses `&& rm -rf /var/lib/apt/lists/*` (manual cleanup, no cache mount) and `lib/preview/Dockerfile:9` uses no mount on `bundle install`.

### Phase 4 plan touchpoints on image size

The plan at `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md` references the preview image size implicitly in:

- **Phase 9 pre-deploy hook** (lines 1265-1316): `docker build -f Dockerfile.base ...` runs on the Hetzner host on every `kamal deploy`. Estimated cold time **≈5 min**, warm **≈25 s** when Gemfile.lock layer cache hits (line 1299, 1916). The plan does not propose any Dockerfile changes.
- **Phase 10 PreviewManager additions** (lines 1340-1693): all changes are control-plane (kamal-proxy register/deregister, `--internal` network, healthcheck flip to `docker exec ... curl`). No Dockerfile edits.
- **Performance Considerations** (lines 1914-1920): "Pre-deploy hook: ~25s warm (preview-base layer cache hits when Gemfile.lock unchanged); ~5min cold on first deploy. … Preview cold start: ~30-90s (docker build + bundle + healthcheck loop) — unchanged from Phase 3."
- **Disk pressure**: the plan's Hetzner box has 150 GB disk (Current State Analysis line 34). At 894 MB per `preview-base` plus per-project deltas, plus three coexisting Kamal apps, no explicit disk budget is computed in the plan.

The healthcheck change in Phase 10 §6 (`docker exec preview-<id> curl -fsS http://localhost:3000/up`) depends on `curl` being installed in the preview container — which it is, from `Dockerfile.base:5`.

## Code References

- `lib/preview/Dockerfile.base:1-17` — base image build (single-stage, 17 lines, produces 894 MB)
- `lib/preview/Dockerfile:1-22` — per-project image (FROM preview-base, COPY workspace, bundle install delta, tailwindcss:build)
- `lib/preview/skeleton/Gemfile:1-63` — 116-gem skeleton bundle, dev/test groups present
- `lib/preview/skeleton/Gemfile.lock:551` — total lock-file lines; `PLATFORMS` block carries 10 platforms incl. both -gnu and -musl
- `lib/preview/skeleton/.dockerignore:1-37` — context exclusions (lives in skeleton/, applies to per-project builds only)
- `lib/preview/skeleton-overlay/.dockerignore` — slimmer overlay variant, applied at workspace init
- `lib/preview/skeleton/Dockerfile:1-79` — multi-stage reference (skeleton-internal, not used by preview pipeline)
- `Dockerfile:1-67` — top-level generator Dockerfile, multi-stage with `BUNDLE_WITHOUT="development"` + cache cleanup
- `bin/preview-rebuild-base:1-13` — base-image rebuild script (called manually + by Phase 4 pre-deploy hook)
- `bin/preview-regen-skeleton:1-32` — skeleton refresh script (run on Rails minor bumps; adds linux platforms)
- `lib/preview/preview_manager.rb:32-50` — `start` orchestrates `build_image` + `run_container` + healthcheck (Phase 4 plan adds kamal-proxy registration here)
- `.ruby-version:1` — `ruby-4.0.2` (the `ruby-` prefix is stripped before passing as `RUBY_VERSION` arg per `feedback_ruby_version_prefix.md`)

Image-layer measurements (from `docker history preview-base:latest` on this host, 2026-04-28):

| Layer command | Size |
|---|---|
| `RUN /bin/sh -c bundle install` | 347 MB |
| `COPY skeleton/Gemfile skeleton/Gemfile.lock` | 26.4 kB |
| `RUN /bin/sh -c apt-get update && apt-get ins…` (build-essential libsqlite3-dev libyaml-dev curl git) | 348 MB |
| Ruby install layer | 94.9 MB |
| Initial apt update | 3.83 MB |
| Debian trixie slim | 100 MB |
| **Total** | **894 MB** |

## Architecture Documentation

The preview-image stack is two-layer by design:

1. **`preview-base:latest`** is the cached, expensive-to-build image — it bakes Rails 8 + the skeleton bundle. Built once per skeleton/Gemfile change (in dev: `bin/preview-rebuild-base`; in prod: Phase 4 pre-deploy hook on Hetzner).
2. **`preview-<id>:<tag>`** per project — `FROM preview-base`, COPY workspace, delta bundle, tailwind build. Built every time a preview is started (`Preview::PreviewManager#build_image`).

The split exists to amortize the bundle install across project builds: a per-project preview image build only re-runs the bundle install if the workspace's Gemfile.lock differs from the skeleton's (Bundler short-circuits when all gems are present in `BUNDLE_PATH`). Tailwind build is fast (~1-3 s) because it's a single native-binary invocation.

Today's `Dockerfile.base` does not apply the multi-stage / `BUNDLE_WITHOUT` / cache-cleanup patterns that `Dockerfile` (top-level) and `lib/preview/skeleton/Dockerfile` (skeleton-internal) do.

## Historical Context (from thoughts/)

- `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md` — Phase 4 plan; production deploy on Hetzner. Phase 9 §1 (lines 1265-1316) rebuilds `preview-base` on the host via the pre-deploy hook. Phase 10 (lines 1340-1693) doesn't touch the Dockerfiles.
- `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md` — Phase 3 plan (preview isolation via Docker), the predecessor that established the current `Dockerfile.base` + `Dockerfile` + `preview_manager.rb` pipeline.
- `thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md` — referenced as `predecessor_research` in the Phase 4 plan front matter; the broader inventory the plan was derived from.
- `docs/02-architecture/03-tech-stack.md` — repo-canonical tech-stack doc; contains the production topology (Kamal + kamal-proxy mention at line 191 per the Phase 4 plan).
- `CLAUDE.md` (Conventions block) — documents the preview-build commands: `bin/preview-rebuild-base` after Gemfile changes, `bin/preview-regen-skeleton` when bumping Rails. Notes that `lib/preview/Dockerfile{,.base}` are owned by this repo and never read from generated apps.

## External References

- [Docker Hub - ruby image](https://hub.docker.com/_/ruby) — official tags listing
- [GitHub - docker-library/ruby](https://github.com/docker-library/ruby) — image source Dockerfiles + size tables
- [GitHub - rails/tailwindcss-rails](https://github.com/rails/tailwindcss-rails) — confirms precompiled binaries via `tailwindcss-ruby`, no Node
- [GitHub - rails/importmap-rails](https://github.com/rails/importmap-rails) — confirms pure Ruby, no Node runtime dep
- [Rails Dockerfile.tt template (rails/rails)](https://github.com/rails/rails/blob/main/railties/lib/rails/generators/rails/app/templates/Dockerfile.tt) — upstream of `lib/preview/skeleton/Dockerfile`
- [Rails app_base.rb (package method definitions)](https://github.com/rails/rails/blob/main/railties/lib/rails/generators/app_base.rb) — defines `dockerfile_base_packages` / `dockerfile_build_packages`
- [BuildKit cache mounts (vsupalov.com)](https://vsupalov.com/buildkit-cache-mount-dockerfile/) — explains `RUN --mount=type=cache` semantics
- [Docker Docs - Optimize cache usage](https://docs.docker.com/build/cache/optimize/) — BuildKit cache patterns
- [Debian package - libsqlite3-0](https://packages.debian.org/stable/libs/libsqlite3-0) — runtime SQLite shared lib
- [Debian package - libyaml-0-2](https://packages.debian.org/sid/libyaml-0-2) — runtime YAML shared lib
- [Debian package - libvips42](https://packages.debian.org/sid/libvips42) — runtime libvips for ActiveStorage variants
- [GitHub - Rails Issue #46855 (Dockerfile shrink case study)](https://github.com/rails/rails/issues/46855) — historical 1.6 GB → 600 MB reduction story

## Related Research

- `thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md` — Phase 4 baseline research (referenced but not directly read for this size-focused study)

## Open Questions

These are documentation gaps, not recommendations — items a follow-up plan would have to settle:

1. **Disk budget on the Hetzner host.** Phase 4's plan does not enumerate "max simultaneous preview-base + per-project image footprint" against the 150 GB disk. With `preview-base = 894 MB`, base-overlay-on-different-skeleton-versions during transitions, plus per-project image accumulation, the working set is unspecified.
2. **Whether `--internal` Docker network in production breaks `bundle install`** during the per-project image build. The per-project Dockerfile's `RUN bundle install` line (line 9) needs egress to rubygems.org. In production the `preview-internal` network is `--internal` (Phase 10 §1), but image **build** runs on the host's default `bridge` network, not the container's run-time network — so bundle install during build is unaffected. Confirmed by inspection; not stated in the plan.
3. **Tailwind build inside `--internal` containers**: `bin/rails tailwindcss:build` needs no network (binary is bundled), and runs at image-build time anyway — same as bundle install above, runs on the build network not the run network.
4. **Per-project image cleanup cadence on the host.** `Preview::PreviewManager#stop` runs `docker image rm -f <project_tag>` (`preview_manager.rb:#stop` per Phase 4 plan §3). A long-running preview that's never stopped never has its image reaped; the compounded image graph on the host is not bounded.
5. **Whether `image_processing` gem needs `libvips` at runtime** in the preview. The skeleton Gemfile includes `image_processing ~> 1.2`. `Dockerfile.base` does not install `libvips42`. If a generated preview uses ActiveStorage variants, the runtime call into `image_processing` would fail. Out of scope for size analysis but flagged.
6. **`tzdata` package**: Ruby's stdlib `Time` uses the OS tz database. The `ruby:4.0.2-slim` base image includes `tzdata` (verified upstream). Not a concern.
7. **Ruby 4.0.2 version-specific image-size table**: no public per-tag uncompressed-size table found for 4.0.2 specifically; sizes inferred from Ruby 3.4.1 reference data (slim ≈ 219 MB, alpine ≈ 99 MB, full ≈ 1.01 GB). The 100 MB + 95 MB layers measured in `docker history preview-base:latest` for Ruby 4.0.2-slim sum to ≈ 195 MB, consistent with the 3.4.1 slim reference of 219 MB.
