# Changelog

All notable changes to hifumi.dev are documented in this file. It is kept
from 1.0.0 onward: every release gets a dated section here describing what
changed, added with the change itself.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [semantic versioning](https://semver.org/) (minor for new
functionality, patch for fixes and internal changes).

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
