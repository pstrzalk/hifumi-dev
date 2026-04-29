---
date: 2026-04-28
author: Paweł Strzałkowski (with Claude)
status: ready-for-implementation
phase: 4
part: d
scope: lean
predecessor_research: thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md
predecessor_plan: thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md
---

# Phase 4 — Production deploy on Hetzner with kamal-proxy + multi-tenancy
## Part D: Deploy & Wrap-Up (Phases 11–13)

> **Plan split into 4 parts (header duplicated in each):**
> - A: Phases 1–4 — auth + ownership + per-user OpenRouter key (`phase-4a-auth-and-ownership.md`)
> - B: Phases 5–7 — preview lifecycle refactors (`phase-4b-preview-refactors.md`)
> - C: Phases 8–10 — production infrastructure (`phase-4c-deploy-infrastructure.md`)
> - **D** (this file): Phases 11–13 — Resend SMTP + first deploy + smoke, retro doc, docs refresh; plus Testing Strategy / Performance / Migration / References

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

## Phase 11: Resend SMTP + Devise mailer + initial deploy + smoke

### Commit
`phase 4 step 11: Resend SMTP wiring + Devise mailer for password reset`

(The deploy itself isn't a commit; the smoke check is verification work that happens after this commit lands.)

### Overview

Configure Action Mailer for Resend SMTP in production, point Devise at the right sender, then perform the first production deploy and end-to-end smoke.

### Changes Required

#### 1. Resend SMTP configuration

**File:** `config/environments/production.rb`

Replace the commented `smtp_settings` block with:

```ruby
# SMTP transport — currently bound to Resend, swappable to any SMTP-speaking
# provider (Postmark, SendGrid, SES, etc.) by changing host/username and the
# SMTP_PASSWORD env value. No provider-specific gem, no API client, no
# webhooks — Action Mailer's stock SMTP only, per "zero vendor lock-in".
config.action_mailer.delivery_method = :smtp
config.action_mailer.smtp_settings = {
  address:        "smtp.resend.com",   # provider host
  port:           587,
  user_name:      "resend",            # provider username (Resend uses literal "resend")
  password:       ENV.fetch("SMTP_PASSWORD"),
  authentication: :plain,
  enable_starttls_auto: true
}
config.action_mailer.default_url_options = { host: "hifumi.dev", protocol: "https" }
config.action_mailer.raise_delivery_errors = true
```

#### 2. Devise mailer sender

**File:** `config/initializers/devise.rb`

```ruby
config.mailer_sender = "noreply@hifumi.dev"
```

(May already be set from Phase 1 — verify.)

#### 3. Resend (sending domain provisioned 2026-04-28)

`hifumi.dev` is registered as a Resend sending domain and verified. Sender identity ready for `noreply@hifumi.dev` via SMTP. Only remaining operator action before first deploy: **generate a Resend API key and export it as `SMTP_PASSWORD`** in the shell where `kamal setup`/`kamal deploy` will be run (Resend dashboard → API Keys → Create; the `re_...` value is the SMTP password). The env var is named `SMTP_PASSWORD` (not `RESEND_API_KEY`) so swapping to Postmark/SendGrid/SES later is a values-only change — no var rename.

#### 4. DNS (live at GoDaddy, propagated 2026-04-28)

Authoritative state (queried against `ns07.domaincontrol.com`):

| Type | Name | Value | Purpose |
|------|------|-------|---------|
| A | `@` | `77.42.95.154` | Generator at `hifumi.dev` |
| A | `*.preview` | `77.42.95.154` | Wildcard for every `<id>.preview.hifumi.dev` |
| CNAME | `www` | `hifumi.dev` | Apex alias |
| TXT | `@` | `v=spf1 include:dc-fd741b8612._spfm.send.hifumi.dev ~all` | Root SPF (Resend) |
| TXT | `send` | `v=spf1 include:dc-fd741b8612._spfm.send.hifumi.dev ~all` | Send-subdomain SPF |
| TXT | `dc-fd741b8612._spfm.send` | `v=spf1 include:amazonses.com ~all` | Resend tracking-subdomain SPF (chains to Amazon SES) |
| MX | `send` | `10 feedback-smtp.eu-west-1.amazonses.com.` | Bounce processing (Resend, EU region) |
| TXT | `resend._domainkey` | `p=MIGfMA0GCSqGSIb3DQEBAQU...` (RSA pubkey) | DKIM (Resend) |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; adkim=r; aspf=r; rua=mailto:dmarc_rua@onsecureserver.net;` | DMARC (GoDaddy default; relax to `p=none` if first sends quarantine) |

Resend uses a unique tracking subdomain (`dc-fd741b8612._spfm...`) so the apex SPF stays short and Resend is removable later by deleting their records — no surgery on root SPF needed.

Verification command (one-shot, hits authoritative GoDaddy NS to bypass resolver caches):

```bash
for q in "hifumi.dev A" "anything.preview.hifumi.dev A" "www.hifumi.dev CNAME" "hifumi.dev TXT" "send.hifumi.dev TXT" "send.hifumi.dev MX" "resend._domainkey.hifumi.dev TXT" "_dmarc.hifumi.dev TXT"; do
  echo "=== $q ==="; dig @ns07.domaincontrol.com $q +short
done
```

#### 5. First deploy

```bash
cd /Users/pawel/projects/rails-app-generator
export SMTP_PASSWORD="re_..."   # Resend API key today; same env var name regardless of future SMTP provider
bundle exec kamal setup    # first time only; subsequent: kamal deploy
```

Watch output:
- Pre-deploy hook fires (network create, kamal-proxy attach, preview-base build)
- Image builds locally, pushes to `localhost:5555` on the host
- Container starts, healthcheck (`/up`) passes
- kamal-proxy fetches LE cert for `hifumi.dev` on first request

#### 6. End-to-end smoke

Manual checklist (see Desired End State § Verification):

1. `curl -I https://hifumi.dev` → 200, valid cert.
2. Browse `https://hifumi.dev` (anonymous) → welcome page.
3. Sign up with real email + Resend-deliverable address → confirm landing on `/projects`.
4. Use the "forgot password" flow → confirm email arrives via Resend.
5. Create a project, send instruction → confirm chat reply streams.
6. Wait for instruction to complete → click Start preview → wait for `running` state.
7. Click iframe link → `https://<id>.preview.hifumi.dev` opens in new tab → see live app, valid cert.
8. From a private window, hit same URL → see live app (proves public).
9. From private window, hit `https://hifumi.dev/projects/<id>` → redirected to login (proves studio is owner-only).
10. As owner, click Stop → wait `:stopped` → hit preview URL → kamal-proxy default no-route response (no branded page in Lean Phase 4).
11. `ssh root@77.42.95.154 'docker exec preview-<id> curl https://example.com'` after starting fresh → fails (egress blocked).
12. `curl -I https://perfectpitch.world` → still 200 (other tenants unaffected).
13. **Preview-survives-deploy check**: with a preview running for some test project, run `bundle exec kamal deploy` from the generator dir → after deploy completes, the preview container is still listed in `docker ps` on the host with the same container id, the project's DB row stays `:running`, `kamal-proxy list` still shows the route, and a private-window request to `https://<id>.preview.hifumi.dev` returns the live app uninterrupted. (Validates the orphan-reset rewrite under real Kamal restart conditions.)
14. **Log-scrub spot check**: `ssh root@77.42.95.154 'docker logs hifumi-generator-web-1 2>&1 | grep -E "sk-or-[A-Za-z0-9_-]{16,}"'` → no matches. Same for `journalctl -u docker` and any Solid Queue worker output.

### Success Criteria

#### Automated Verification:
- [ ] `bin/rails test` passes
- [ ] `Devise::Mailer.reset_password_instructions` test renders without error in test env
- [ ] `bundle exec kamal config` lints clean

#### Manual Verification:
All 12 smoke checks above.

**Implementation Note**: This is the riskiest phase. If anything fails, debug live; do not proceed to docs phase until smoke is green.

---

## Phase 12: Phase 4 retrospective doc

### Commit
`phase 4 step 12: Phase 4 retro doc`

### Overview

Write `docs/03-plans/03-phase-4-production-deploy.md` capturing what happened, what surprised, what got deferred. Lightweight — 1-2 pages, mirroring the structure of `docs/03-plans/02-phase-3-preview-isolation.md`.

### Changes Required

**File:** `docs/03-plans/03-phase-4-production-deploy.md` (new)

Sections:
- Status (closed at production-deploy level)
- Decisions made (link back to this plan's Q&A)
- What worked
- What surprised (manual notes added during deploy)
- Deferred to Phase 5 (the B-tier list — per-container subnets, wake-on-request, publish/unpublish, gVisor, multi-host, monitoring, DNS-01 wildcard cert, key rotation strategy, branded offline page for stopped previews)

### Success Criteria

#### Automated Verification:
- [ ] File exists; markdown lints clean

#### Manual Verification:
- [ ] Reads coherently; future-you can pick up the Phase 5 list from it

---

## Phase 13: CLAUDE.md status update + tech-stack docs refresh

### Commit
`phase 4 step 13: CLAUDE.md status, tech-stack, vision endpoint shape`

### Overview

Update the canonical status line in `CLAUDE.md` (Phase 4 closed, Phase 5 candidates listed). Update `docs/02-architecture/03-tech-stack.md` to describe the production topology (Kamal + kamal-proxy + Resend + per-user OpenRouter). `docs/01-vision/02-user-journey.md:428` already names the Phase 4 endpoint shape — verify it's accurate, no edit needed if so.

### Changes Required

#### 1. `CLAUDE.md` status block

**File:** `CLAUDE.md`

Replace the Phase 3 / Phase 4 lines under `## Status` with:

```markdown
- **Phase 3** (preview isolation via Kamal + Docker): closed at the local-PoC level on 2026-04-27.
- **Phase 4** (production deploy on Hetzner with kamal-proxy + DNS + per-host TLS + strict --internal network + per-user OpenRouter BYOK + Devise multi-tenancy): **closed** on 2026-04-2X. Generator at https://hifumi.dev; previews at https://<id>.preview.hifumi.dev. Plan: `thoughts/shared/plans/2026-04-28/phase-4-production-deploy.md`. Retro: `docs/03-plans/03-phase-4-production-deploy.md`. **Phase 5** candidates: per-container network subnets, wake-on-request, explicit publish/unpublish, gVisor/Firecracker, multi-host LB, monitoring dashboards, DNS-01 wildcard cert, branded offline page for stopped previews (kamal-proxy v0.9 wildcard limitation), key rotation, fork-this-project, model-selection UI, **Docker socket-proxy in front of `/var/run/docker.sock`** (mitigates the `USER root` + bound socket exposure today; an RCE in the generator currently grants full host root via the daemon).
```

#### 2. `docs/02-architecture/03-tech-stack.md` refresh

Add a "Production deployment" subsection describing the Hetzner host, kamal-proxy as router (already present at line 191 mention), Resend as transactional mail, and the per-user BYOK model.

#### 3. Update Convention block in `CLAUDE.md`

Update the "Preview infrastructure" line:

```markdown
- **Preview infrastructure**: `lib/preview/preview_manager.rb` drives Docker. In production, `Preview::Config.remote?` switches the network to `--internal` and adds kamal-proxy registration on start (`docker exec kamal-proxy kamal-proxy deploy/remove`). Pre-deploy hook (`.kamal/hooks/pre-deploy`) bootstraps the network, attaches kamal-proxy to `preview-internal`, and builds `preview-base:latest`. Read ENV only in `config/initializers/preview_config.rb` → `Preview::Config` wrapper exposes typed accessors.
```

### Success Criteria

#### Automated Verification:
- [ ] `markdownlint CLAUDE.md docs/` reports no errors

#### Manual Verification:
- [ ] CLAUDE.md status block reads accurately
- [ ] `git log --oneline | head -20` shows the 14 phase commits with sane messages

---

## Testing Strategy

### Unit Tests (per phase)
- `User`, `Profile` model tests — encryption round-trip, validation presence
- `Preview::Config` wrapper — branch on `domain` presence
- `Project#preview_url` — both branches stubbed via `Preview::Config`
- `PreviewManager` — kamal-proxy commands invoked / skipped per `Preview::Config.remote?`
- `ExecuteInstructionJob#roast_executable` — env-branch helper picks correct script

### Integration Tests
- `Devise::RegistrationsControllerTest` — full signup form roundtrip, including nested Profile params
- `ProjectsControllerTest` — auth gate, ownership enforcement, index ordering, destroy
- `MessagesControllerTest`, `PreviewsControllerTest` — non-owner returns alert
- Existing `E2E_PREVIEW=1 bin/rails test test/integration/preview_lifecycle_test.rb` — must continue to pass in dev (kamal-proxy code paths skipped via `Preview::Config.remote?` false)

### Manual Smoke (Phase 11)
The 12-step end-to-end checklist above.

## Performance Considerations

- **Pre-deploy hook**: ~25s warm (preview-base layer cache hits when Gemfile.lock unchanged); ~5min cold on first deploy.
- **Kamal deploy**: image build + push to localhost:5555 + boot ~3-5min total. Acceptable for a single-developer cadence.
- **Per-preview Let's Encrypt cert fetch**: 1-3s on first request to a preview hostname. Subsequent requests hit cached cert.
- **kamal-proxy registration latency**: `docker exec kamal-proxy kamal-proxy deploy ...` is sub-second.
- **Preview cold start**: ~30-90s (docker build + bundle + healthcheck loop) — unchanged from Phase 3.

## Migration Notes

- **Dev DB**: nuked at Phase 2 (`db:drop db:create db:migrate`). No backfill, no seed user.
- **Prod DB**: fresh, no migration concern. First deploy creates the schema.
- **Preview-base image**: built by pre-deploy hook on first deploy. No manual seeding required.
- **kamal-proxy state**: existing routes for `perfectpitch.world`, `touchtype.<...>`, `blind_cv_generator.<...>` are untouched. New route for `hifumi.dev` adds via Kamal's normal flow; preview routes register dynamically per-preview.

## References

- Original research: `thoughts/shared/research/2026-04-27/phase-4-knowledge-baseline.md`
- Predecessor plan: `thoughts/shared/plans/2026-04-27/phase-3-preview-isolation.md`
- Phase 3 analysis (architecture diagram, kamal-proxy contracts): `docs/03-plans/02-phase-3-preview-isolation.md`
- Vision endpoint shape: `docs/01-vision/02-user-journey.md:428`
- W3 workflow contract: `docs/02-architecture/01-workflows-and-decisions.md:138-154`
- Pre-existing kamal-proxy on host: `docker ps` confirmed `basecamp/kamal-proxy:v0.9.0` on 80/443 routing 3 tenants
- RubyLLM gem (per-instance api_key): verify exact API at impl time per `ruby-llm-v1` skill
- Devise nested attributes pattern: standard Rails — `accepts_nested_attributes_for` + custom RegistrationsController
- Memories applied: `feedback_state_by_absence`, `feedback_derive_dont_store`, `feedback_no_logic_in_views`, `feedback_no_service_objects`, `project_dev_cable_solid`, `project_ruby_llm_*`, `project_form_replace_over_redirect`
