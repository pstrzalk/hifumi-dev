# Changelog

All notable changes to hifumi.dev are documented in this file. It is kept
from 1.0.0 onward: every release gets a dated section here describing what
changed, added with the change itself.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semantic versioning](https://semver.org/) (minor for new
functionality, patch for fixes and internal changes).

## [Unreleased]

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
