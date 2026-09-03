# Changelog

All notable changes to hifumi.dev are documented in this file. It is kept
from 1.0.0 onward: every release gets a dated section here describing what
changed, added with the change itself.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semantic versioning](https://semver.org/) (minor for new
functionality, patch for fixes and internal changes).

## [1.5.2] - 2026-09-04

### Fixed

- 1.5.1 put the right gems in the image but the build steps kept
  reinstalling them. The step runner strips every `BUNDLE_*` variable before
  spawning the code agent and the verification commands, and that took the
  image's `BUNDLE_PATH` and `BUNDLE_WITHOUT` with it, so Bundler looked in the
  wrong directory and asked for the development group the image never
  installs. The agent wrapper and the verification step now restore those two
  variables, and the automatic `bundle install` remediation runs against the
  project's Gemfile instead of the generator's. Verified against production
  by reproducing the failure with the variables stripped and the pass with
  them restored.

## [1.5.1] - 2026-09-03

### Fixed

- Every build step on hifumi.dev was silently paying for a full `bundle
  install`. The generator image's gems had moved past the versions pinned in
  the blank-app skeleton every project starts from, and the agent sandbox is
  that same image, so Bundler inside the sandbox could not satisfy the
  project's lockfile and downloaded all 116 gems again — in a container that
  is discarded a minute later. On a six-step build that was about nine of
  thirty-two minutes, an extra fix-agent call per step, and the verification
  step never reaching the tests before remediation. The image now carries the
  skeleton's bundle as well, and its build fails if the two ever drift again.
  Self-hosters: rebuild the image; the build takes a little longer, every
  build step afterwards is faster and cheaper.

## [1.5.0] - 2026-09-03

### Added

- Change requests are now planned against the application as it actually is.
  Before asking the model for a plan, hifumi.dev reads the project's workspace
  — the gems installed beyond the Rails defaults, the database tables and
  their columns, the routes file, the list of source files under `app/`, and
  the project's own `docs/` — and hands that to the planner alongside the
  request. Plans name the real files, columns, routes and colours instead of
  guessing: "let people delete an entry" no longer invents an authorization
  step for an app that has no users, and a styling tweak names the template's
  actual hex value rather than a CSS variable the app does not have. The first
  build of a project is unaffected; there is no application to read at that
  point. The snapshot travels with every change request's planning call — a
  few kilobytes for a fresh app, up to ~35 KB for the largest existing one — so
  plans cost a little more on a bring-your-own-key account.
- Three maintainer scripts for plans, none of which persists anything.
  `bin/inspect-plan-application-modification <project_id> "<intent>"` dry-runs
  the change planner and prints the workspace snapshot and the plan it
  produces; `--blind` shows what the planner would have done without the
  snapshot. `bin/inspect-plan-application-creation` dry-runs the first-build
  planner and works again — the RubyLLM 2.0 upgrade had broken it.
  `bin/inspect-plans <project_id>` reads back every plan already stored for a
  project without calling a model.

### Changed

- Both planner prompts stopped asserting things that were never true of a
  generated app: that Devise is installed (it is not — sign-in is planned with
  Rails' own `has_secure_password` and sessions) and that hifumi.dev's own
  design tokens such as `--accent` exist in the generated app. Plans that used
  to hedge ("if it uses a CSS class…", "assuming a User model exists") are told
  not to, now that they can see the answer.
- The documentation agent that runs after every build step is now asked to
  keep each of the four `docs/` files under 8 000 characters, condensing stale
  sections instead of appending to them. The planner reads each file up to
  that length and cuts it there, per file — an oversized file loses its tail,
  never a sibling file.

## [1.4.0] - 2026-08-24

### Changed

- The conversation layer moved to RubyLLM 2.0. Nothing changes in how the app
  behaves — chat still streams, builds still start from the same two tools —
  but self-hosters upgrading past this point should know two things. First, the
  gem is pinned to a specific commit of its `main` branch rather than a
  released version, because 2.0 has not shipped to RubyGems yet. Second, the
  upgrade runs a **one-way** migration: it renames `models` to
  `ruby_llm_models` and `tool_calls` to `ruby_llm_tool_calls` in place, moves
  per-message token counts into a new `ruby_llm_usages` table, and drops the
  columns it replaced. There is no `down`, and the migration runs
  automatically when the container boots, so a deploy is what triggers it.
  Snapshot the database first; the procedure is in
  `docs/05-runbooks/04-ruby-llm-v2-rollout.md`.

## [1.3.0] - 2026-08-18

### Added

- Assistant replies in chat are now formatted. Bold, italics, bulleted and
  numbered lists, inline code and multi-line code blocks render as intended,
  instead of showing the raw `**`, `###` and backtick markers the model has
  always written. The rendered set is deliberately small: headings, block
  quotes, tables and strikethrough flatten to plain text, and links and images
  are never rendered as such — a markdown link keeps its label, so the agent is
  asked to write URLs plainly and leave them readable. Text still streams in as
  plain text and formats once the reply finishes. Nothing is stored formatted,
  so older conversations pick up the change too.
- Claude Sonnet 5 and Claude Opus 5 can be selected for any of the six
  generation stages, both as account defaults and per project. Stage defaults
  are unchanged, so existing projects keep the models they were created with.

### Changed

- Preview subdomains now use the pre-issued wildcard certificate that 1.2.0
  added as opt-in. A first visit no longer waits for a certificate to be
  issued, and the certificate-transparency warning that a slightly fast clock
  could trigger is gone.

### Fixed

- Selecting Claude Sonnet 4.6 or Claude Opus 4.6 did not actually work: chat
  answered with "The configured model is unavailable", and a project using one
  for its template stage failed mid-build. Only the default Haiku model
  resolved. Both environments are corrected, and a new check fails loudly if a
  model offered in the picker cannot be resolved, so the picker and what the
  system can actually run cannot drift apart again silently.

### Security

- No model-authored HTML is ever rendered in chat. The new formatting passes
  every reply through a CommonMark parser that omits raw HTML outright and then
  an allowlist sanitizer, because the app's content-security policy permits
  scripts from any HTTPS origin and so cannot be relied on as a second line of
  defense.
- Twelve gems updated for newly published advisories — among them nokogiri,
  rails-html-sanitizer, loofah, sqlite3 and websocket-driver — together with
  the Rails 8.1.3.1 patch releases.

## [1.2.0] - 2026-06-16

### Added

- Previews can now be served by a pre-issued wildcard `*.preview.hifumi.dev`
  certificate instead of a brand-new per-host certificate minted on first
  visit. Set `PREVIEW_TLS_CERTIFICATE_PATH` and `PREVIEW_TLS_PRIVATE_KEY_PATH`
  (paths inside the kamal-proxy container) to switch over; unset keeps the
  previous on-demand behavior. A long-lived wildcard certificate sidesteps the
  "connection is not private" / certificate-transparency warning a visitor with
  a slightly slow clock could see on a seconds-old certificate, and removes the
  first-visit issuance wait. See `docs/05-runbooks/02-preview-wildcard-tls.md`.

### Changed

- Hardened the generator's cookies and headers now that untrusted, user-built
  preview apps share the `hifumi.dev` parent domain: the production session
  cookie uses the `__Host-` prefix (un-shadowable by a preview subdomain),
  cookies are marked `Secure` (`force_ssl` + `assume_ssl`), the remember-me
  cookie is `Secure`/`SameSite=Lax`, and every response advertises
  `Origin-Agent-Cluster: ?1`. Existing sessions are invalidated once on deploy
  (the session cookie is renamed), so users will need to sign in again.

## [1.1.3] - 2026-06-12

### Fixed

- The first visit to a brand-new project's preview could hit the browser's
  "connection is not private" warning: the preview was announced as running
  before its subdomain certificate existed, because certificates are issued
  on demand at the first visit. The preview now requests its own public URL
  once during startup, so the certificate is ready before the user ever
  clicks the link. A slow certificate authority degrades gracefully back to
  the old behavior instead of blocking a working preview.

## [1.1.2] - 2026-06-12

### Fixed

- Generated apps with an existing master key failed to boot inside the
  sandbox: the key file was kept readable by root only, and Rails reads it
  whenever it exists — even with empty credentials — so verification died
  with a permission error and the agent could not run Rails commands. The
  key is now world-readable within the project workspace (still writable
  only by its owner), which every container that legitimately boots the app
  already had access to.

## [1.1.1] - 2026-06-12

### Fixed

- Sandboxed generation failed in production with "attempt to write a readonly
  database": with all capabilities dropped, root loses its permission-bit
  bypass, and the sandbox mixed a root-run workflow with a uid-1000 agent, so
  neither could write files the other created. The sandbox now runs entirely
  as the unprivileged generator user and the workspace is made writable before
  every sandboxed run.

### Security

- The sandbox container keeps zero Linux capabilities — the SETUID/SETGID
  pair previously retained for the root-to-generator privilege drop is no
  longer needed now that the container starts unprivileged.

## [1.1.0] - 2026-06-12

### Added

- Per-project LLM model selection: the six generation stages (chat, plan
  creation, plan modification, template, code, docs) each carry their own
  model. Users set per-stage defaults in the account pane; each project
  snapshots them at creation and can change them later in the build tab.
  Applies on the OpenRouter path; a curated model list guards against
  unsupported selections.

### Security

- Per-instruction agent sandbox: in production, each code-generation run
  executes in a throwaway Docker container that mounts only that project's
  workspace, has no Docker socket, drops all capabilities except
  SETUID/SETGID, and receives secrets by environment variable name — never
  on the command line.
- CI now gates on bundler-audit; gems with known CVEs bumped and Brakeman
  configuration tightened.

## [1.0.0] - 2026-05-15

First public release, live at [hifumi.dev](https://hifumi.dev).

### Added

- Conversational Rails app generation: describe an app in chat and an agent
  plans it, then builds it through deterministic, verified revisions
  (RubyLLM chat, Roast workflow pipeline, Solid Queue jobs).
- Plan creation and modification through chat, with a visual template stage
  that picks a design-system starting point for the generated app.
- Generated apps are plain Rails repositories with their own git history —
  no runtime dependency on hifumi.dev, zero vendor lock-in.
- Live preview: each project can boot in a hardened, resource-capped Docker
  container, started and stopped from the project page and embedded next to
  the chat.
- Accounts: email/password and Sign in with GitHub. Each user brings their
  own OpenRouter API key, encrypted at rest.
- Production deployment on Kamal (Hetzner), with previews served on
  per-project subdomains via kamal-proxy.
- Hifumi design system across the whole UI.
