# Changelog

All notable changes to hifumi.dev are documented in this file. It is kept
from 1.0.0 onward: every release gets a dated section here describing what
changed, added with the change itself.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semantic versioning](https://semver.org/) (minor for new
functionality, patch for fixes and internal changes).

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
