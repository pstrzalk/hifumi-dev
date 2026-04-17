# Vision and principles

> **From PROMPT to IPO.**
> Convention over configuration means agents write token-efficient code that's easy to generate and beautiful for humans to review.
> — inspired by rubyonrails.org (2026)

Ruby on Rails application generator — equivalent of Lovable/bolt.new for the Rails ecosystem.

## Vision

Rails positions itself as the optimal framework for AI agents — convention over configuration means fewer tokens, fewer decisions, better output. We take this literally: a tool that, given a natural-language description, generates a complete Rails application. The user says e.g. "Build an app for selling and delivering flowers", and the system guides them through the process of building a ready app.

**This is a tool that popularizes Ruby on Rails.** The output is a clean Rails repo — zero vendor lock-in, zero proprietary gems. `git clone`, `bundle install`, `rails server`. The user continues with standard tools: any editor, any CI, any hosting. Our generator is a ramp-up, not a cage.

## Fixed assumptions (non-negotiable)

- **Main application** (the generator itself) — Ruby on Rails
- **Generated applications** — Ruby on Rails

## Generation process concept

Two paths, chosen by the user:

### Path A: Quick generate
1. **Input** — user describes the app
2. **Generation** — system makes decisions on its own, opinionated defaults, fast result
3. **Iteration** — user modifies what they got

### Path B: Guided generate
1. **Input** — user describes the app
2. **Clarifying questions** — 2-3 clarifying questions
3. **Scaffolding** — rails generators, Tailwind, SQLite, standard Rails solutions
4. **Domain modeling** — models, relations, validations
5. **Capabilities** — subsequent phases deliver functionality
6. **Layout/design** — colors, fonts, layout (later step)

## Technical decisions

### Stack of generated applications
- Maximally "Rails Way" — conventions, generators, built-in solutions
- Tailwind CSS
- SQLite (default)
- Solid Cable/Queue/Cache instead of Redis wherever possible
- **Devise** for authentication — handles emails, password reset, and derivative gems (devise_invitable etc.) provide a full ecosystem
- **Hotwire only** — Turbo + Stimulus, no React/Vue
- **HERB + ReActionView** — linting and formatting of ERB files
- Standard Rails approach (Action Mailer, Active Storage, etc.)

Full gem list: `../02-architecture/03-tech-stack.md`.

### Generator interface
- **Web UI from the start** — this is the target form of the product
- **CLI scripts alongside** — every element of the generation process should be runnable from the CLI, so that pipeline steps can be tested, debugged, and verified repeatably

### Rails Way context
- To start: LLM base knowledge + a database of application archetypes (our core IP)
- App manifest (docs/) in generated apps — self-documenting structure
- Future: progressive disclosure — delivering knowledge on demand
- **Ruby on Rails Guides** as the source of truth about conventions. Options: Context7 MCP, direct integration with the guides, our own knowledge base fed from the guides. The Rails Foundation is proud of the Guides — we want to honor them, not route around them.
- Feedback loop: generated apps → feedback on which patterns work → feeds the archetype and knowledge base

### Deployment (future, not yet concrete)
- **Kamal** — if the client wants to deploy themselves (self-hosted)
- **In-house hosting** — if apps are hosted "by us" (SaaS model?)
- Deployment matters, but details to be worked out later

## Deferred

- **In-house hosting** — model to be worked out (Kamal for self-hosted)
- **Mailer styling** — Tailwind for email? Premailer? To be resolved when we tackle mailers.
- **Rails on WebAssembly** — Evil Martians showed that Rails + some gems can run in WASM directly in the browser. To be explored as a "try it now" path for generated projects — zero setup, game-changer for generator UX. Deployment isn't the first concern, but if this worked it would be very strong. Sources: [evilmartians.com/chronicles/ruby-on-rails-on-webassembly](https://evilmartians.com/chronicles/ruby-on-rails-on-webassembly-a-guide-to-full-stack-in-browser-action), continued at [writebook-on-wasm.fly.dev](https://writebook-on-wasm.fly.dev/5/ruby-on-rails-on-webassembly/).
- **LLM token funding** — we need to find a sponsor for token costs. Consciously I don't want to rely on Visuality — if the project takes off, I want to be the sole owner. Anthropic historically gave free tokens, recently less often. To consider: contact with local Anthropic ambassadors, other sponsorship programs.
