# Stack of generated applications

List of tools and gems used in generated applications.
Principle: Rails Way first. A gem only when Rails doesn't have a built-in solution.

---

## Built into Rails (zero extra gems)

What Rails 8 gives out of the box. We use it whenever it fits.

| Area | Solution | Notes |
|------|----------|-------|
| Background jobs | **Solid Queue** | Default in Rails 8. Not Redis. |
| WebSockets | **Solid Cable** | Action Cable backend. Not Redis. |
| Cache | **Solid Cache** | DB-backed cache. Not Redis. |
| Files/uploads | **Active Storage** | Local or S3. |
| Rich text | **Action Text** | WYSIWYG with Trix. |
| Mail | **Action Mailer** | With preview in dev. |
| Frontend | **Turbo + Stimulus** | Hotwire. Zero React/Vue. |
| CSS | **Tailwind CSS** | `rails new --css tailwind`. |
| Database | **SQLite** | Default. Sufficient at start and beyond. |
| Asset pipeline | **Propshaft** | Default in Rails 8. |
| JS bundling | **importmap-rails** | Default. No node_modules. |
| Tests | **Minitest** | Rails default. Fixtures, not factory bot. |
| Recurring jobs | **Solid Queue recurring** | Built in. No extra gem. |

---

## Sure bets (always add)

Gems that solve real problems better than hand-rolled implementations.

### Authentication — Devise

```ruby
gem "devise"
```
- Login, registration, password reset, email confirmation, account lockout
- Derivative ecosystem: `devise_invitable`, `devise-jwt`, etc.
- Why not Rails 8 `generate authentication`: Devise provides the full account lifecycle (emails, password change, invitations). The Rails generator gives only basic login.

### Pagination — Pagy

```ruby
gem "pagy"
```
- Fastest, lightest paginator
- Rails Way: helper + partial, zero magic
- Why not Kaminari: Pagy is faster, simpler, less monkey-patching

### ERB toolchain — Herb + ReActionView

```ruby
gem "herb"
gem "reactionview"
```
- **Herb** — HTML-aware ERB parser written in C. Linter, formatter, LSP, dev tools. Replaces `erb_lint` with a much better parser (understands HTML context, not just ERB tags).
- **ReActionView** — Herb::Engine integration with Rails ActionView. Drop-in replacement. HTML validation during rendering, better errors.
- Herb runs after every revision and in git hooks
- Templates can be `.html.erb` (with interception) or `.html.herb` (native)

### Authorization — Pundit

```ruby
gem "pundit"
```
- Policy objects — simple, predictable pattern
- Rails Way: plain Ruby objects, convention over configuration (app/policies/)
- Why not CanCanCan: Pundit is simpler, explicit, easier to understand for new developers

### Admin panel — Avo (Community Edition)

```ruby
gem "avo"
```
- Modern admin panel, actively developed, good Rails integration
- Free version (Community Edition) to start
- Potential collaboration with Avo creators in the future
- When: the app has an admin panel (most apps)

---

## Conditional (add when needed)

Gems added based on project requirements. The agent decides based on the application description.

### Payments — Pay

```ruby
gem "pay"
```
- Wrapper over Stripe (and Paddle, Braintree)
- Rails integration: models, hooks, webhooks
- When: the app has online payments
- Alternative: `stripe` gem directly if needs are very custom

### Search/filtering — Ransack

```ruby
gem "ransack"
```
- Search forms, sorting, filtering
- When: the app has lists with search/filters (products, orders, etc.)
- Alternative: plain scopes if needs are minimal

### URL slugs — FriendlyId

```ruby
gem "friendly_id"
```
- `/products/red-roses` instead of `/products/42`
- When: the app has public URLs (shop, blog, portfolio)

### Change auditing — PaperTrail

```ruby
gem "paper_trail"
```
- Change history on models
- When: the app requires auditing (finance, medical, legal)

### Data export — Caxlsx

```ruby
gem "caxlsx"
gem "caxlsx_rails"
```
- Excel file generation
- When: the app has reports/exports

### Images — image_processing

```ruby
gem "image_processing", "~> 1.2"
```
- Active Storage variants (resize, crop)
- Requires libvips
- When: the app has image uploads

### Record archiving

- No dedicated gem. Simple implementation: `archived_at` timestamp + scope.
- We don't use soft-delete (Discard, Paranoia) — the concept leads to problems.
- When: data should not be deleted (orders, accounts)

### Decorators — none

- We don't use draper / view_component at the start
- Rails helpers + partials are enough
- We'll consider View Components when UI gets complex

---

## What we do NOT use

| No | Why |
|----|-----|
| Redis | Solid Queue/Cable/Cache replace it |
| React / Vue / Angular | Hotwire only |
| Sidekiq | Solid Queue |
| Webpacker / jsbundling | Importmap |
| Devise alternatives (Sorcery, Clearance) | Devise has the best ecosystem |
| Bootstrap | Tailwind |
| Haml / Slim | ERB + Herb |
| erb_lint | Herb replaces it with a better parser |
| GraphQL | REST + Turbo. GraphQL is overengineering for 99% of apps |
| Docker in development | `rails server`. Simplicity. |
| Soft-delete (Discard, Paranoia) | Leads to problems. Archive via `archived_at`. |
| Multi-tenancy (ActsAsTenant) | Out of reach for now |
| RSpec | Minitest is the Rails Way |

---

## Our application's stack (generator)

Separate list — gems used in the generator itself, not in generated apps.

| Gem | What for |
|-----|----------|
| `ruby_llm` | Conversation layer, chat, tools |
| `roast-ai` (~> 1.1) | Orchestration of generation workflows. **Requires Ruby >= 3.3.** |
| `devise` | Auth for generator users |
| `solid_queue` | Background jobs (generation, preview) |
| `solid_cable` | Turbo Streams (live progress) |
| `tailwindcss-rails` | Generator UI |
| `turbo-rails` + `stimulus-rails` | Hotwire |

### Host requirements

- **Docker** — required on the host for preview containers (Phase 3+). The generator shells `docker build`, `docker run`, `docker network` via `Preview::PreviewManager` (`lib/preview/preview_manager.rb`). Phase 4 will add `kamal-proxy` for routing previews behind a wildcard subdomain.

---

## Deferred decisions

- **Mailer styling** — Tailwind for email? Premailer? To be resolved when we tackle mailers.
