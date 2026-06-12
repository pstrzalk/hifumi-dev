# Follow-ups — ideas

Running list of "to do next" items that surfaced during recent work but aren't large enough (yet) to deserve their own themed idea doc. When an entry grows beyond a few paragraphs of sketch, graduate it to its own `NN-slug.md` and replace the entry here with a one-line pointer.

Date a section header when adding entries so future-you can see the chronology.

---

## 2026-05-14

### Fix the broken E2E generator test

**File**: `test/integration/generate_todo_list_test.rb`

**Symptom (seen during the `update_docs` prompt-cap plan's manual verification)**: `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` finishes in 0.11s instead of the expected ~900s, fails with `Expected #<Instruction phase: "implementing"> to be completed?`. The `user_intent` on the failing record is `"build a flower shop with inventory"` — that exact string lives at `test/fixtures/instructions.yml:6`, so `Instruction.order(:id).last` is matching the loaded fixture rather than an instruction newly-created by the test's POST.

**Why it matters**: this is the only end-to-end safety net for the W1+W2 pipeline. Right now any change to `RevisionPrompt`, `StatCap`, `ExecuteInstructionJob`, etc. has to be validated by hand because the test gives a false signal. The W2.1 prompt hardening shipped 2026-05-14 (`739c844`) is unverified at the agent-behavior level for the same reason.

**Likely shape of the fix** (need to trace before committing):
- The test stub redefines `Chat#complete` to call `CreateApplication.execute(...)`. Either that path isn't reached (so no instruction is created), or it IS reached and creates an instruction, but `.order(:id).last` is still picking up the fixture because the fixture's autoincrement ID happens to outrank the new row's ID.
- First-pass fix candidates: scope by `description` (e.g. `project.instructions.where(user_intent: PROMPT).last`), or assert on `instruction.reload.completed?` only after waiting for a phase transition, or — most robustly — load fewer fixtures in this test class (`fixtures :none` or similar) since this is a full-pipeline test that shouldn't be sharing data with controller-level tests.

**Cost gate**: a real run is ~$5-$10 of Claude tokens + ~8 minutes wall-time. Validate the fix on a fast-failing variant first (e.g. let the test create the project, assert on `project.instructions.count == 1` before any LLM call) before paying for the full pipeline.

---

### Auto-surface preview errors back into the chat

**Motivation**: project 27 (Event RSVP, hifumi.dev) crashed at preview-time with `NoMethodError: undefined method 'authenticate_user!' for an instance of EventsController` because the agent reached for Devise without it being in the Gemfile. The W2.1 prompt hardening (`739c844`) reduces but doesn't eliminate this class of bug. The current recovery flow is "user notices the error in the preview iframe, copy/pastes it into chat, asks the agent to fix it" — but the preview iframe is cross-origin (:3000 → :3027), so the studio JS can't read the error page directly.

**Feasible approach**: server-side log tail on the preview container.

- `PreviewManager` already owns the Docker container's lifecycle (`lib/preview/preview_manager.rb`). Add a `docker logs -f` stream.
- Rails dev mode emits stable per-request lines: `Started GET "/" ...`, `Processing by EventsController#index as HTML`, `Completed 500 Internal Server Error in 42ms`, then `NoMethodError (undefined method ...):` + stack frames. All regex-friendly.
- On a parsed `Completed 5\d\d`, broadcast a Turbo-stream pill into the project's chat with: error class, controller#action, top `app/` frame. Pill carries a "Ask the agent to fix this" button that pre-fills the composer with a fully-formed instruction ("the preview crashes with `<class>` in `<file:line>` — fix it").
- UX bit (chat pill + composer pre-fill) is the bigger lift; detection is the easy half.

**Out of scope alternatives considered**:
- Browser-side iframe scrape: blocked by cross-origin policy.
- Server-side probe (generator's Rails GETs the preview root + sniffs for the dev error page): simpler, but only catches errors on whatever route you probe, adds latency, misses everything below the homepage.
- Skeleton-injected health endpoint reporting last error: most accurate per-request but adds a chunk of skeleton surface area.

---

### W2.4 verify: grep for missing-gem signals

**Motivation**: defense-in-depth in front of the W2.1 prompt hardening (`739c844`). Even if the agent ignores the prompt instructions and writes `before_action :authenticate_user!` (or `Sidekiq::Worker`, or `redirect_to user_path` against a Devise-style route), W2.4 can catch it before the user ever sees a preview crash.

**Sketch**:
- Add a recipe-style check to `VerifyRevision` (or a sibling helper) that scans generated `app/` for known missing-gem signals: `:authenticate_user!` / `current_user` without `devise` in `Gemfile`; `< Sidekiq::Worker` without `sidekiq`; `class .* < ApplicationJob` calling `perform_async` without `sidekiq`; `policy(...)` / `authorize` without `pundit`; `paginate` without `kaminari` or `pagy`.
- Fail fast with a clear error string so W2.R (the LLM-driven remediation loop) gets the same signal the user would have, without the round-trip through the preview iframe.
- Follow the existing recipe pattern in `lib/roast/auto_remediate.rb` (regex + auto-fix proc) — but here the auto-fix would either add the gem to Gemfile + `bundle install` + run `rails g <gem>:install`, OR replace the call with the Rails-built-in equivalent. The first is uniform but expensive; the second is surgical but per-gem.

Pairs naturally with the prompt change — together they cover both "agent didn't know" (prompt) and "agent ignored what it knew" (verify).

---

### Smaller cleanups

- **`ProjectsControllerTest#test_GET_/projects/new_(signed_in)_renders_new_with_placeholder_text`** at `test/controllers/projects_controller_test.rb:43` has been failing on `main` since the projects/new redesign. Test expects `placeholder="a flower shop page, with full payment system"` but the textarea now uses different copy. 5-minute fix: update the assertion to match the current placeholder string (or remove it if placeholder content is no longer a contract worth pinning).
- **Project 20 prod workspace cleanup** (only if the project resumes): 339 MB `vendor/bundle/` + bad commit `5bc7041` from before the skeleton `.gitignore` expansion (`a809a90`). Run `kamal app exec` to drop the tree + amend the commit's tree, or just leave it as historical noise.

---

## 2026-05-15

### OAuth callback 500 when a GitHub account is already linked to another user

**File**: `app/controllers/users/omniauth_callbacks_controller.rb:8`

**Symptom (seen on prod during the rename + secret-rotation audit)**: signing up as a fresh user (User 3 = `pstrzalk+ghtest@gmail.com`) then hitting "Connect GitHub" raised `ActiveRecord::RecordNotUnique (SQLite3::ConstraintException: UNIQUE constraint failed: github_connections.github_user_id)` and returned 500. The OAuth handshake itself succeeded — token exchange completed, GitHub user info was retrieved — but the controller's `update!` violated the unique index because User 1 (`p.strzalkowski@visuality.pl`) already owned a `GithubConnection` for the same `github_user_id`.

**Why it matters**: any second account on hifumi.dev that tries to connect a GitHub identity already linked elsewhere gets a raw 500. Today it was self-inflicted (same person, two accounts) but on a public site it would hit any pair of users sharing access to the same GitHub bot account, or anyone re-registering after deleting their old account.

**The DB invariant is intentional** (one-to-one between GitHub identity and User), so the fix is purely in the controller. Two product choices:

1. **Friendly flash, no transfer** (least surprise): rescue `ActiveRecord::RecordNotUnique`, redirect to `edit_user_registration_path` with `alert: "This GitHub account is already connected to a different hifumi.dev login. Sign in to that account, or disconnect there first."`
2. **Transfer to current user** (most "it just works"): in the rescue, look up the existing connection by `github_user_id`, reassign `user_id` to `current_user.id`, save. Implicit data-ownership swap — fine for a single-user app, surprising on a multi-user one (the original owner silently loses their connection).

Recommend (1) for now — explicit is better than magic.

**Sketch**:

```ruby
def github
  auth = request.env["omniauth.auth"]
  connection = current_user.github_connection || current_user.build_github_connection
  connection.update!(provider: "github_oauth", github_username: auth.info.nickname,
                     github_user_id: auth.uid.to_i, access_token: auth.credentials.token)
  redirect_to edit_user_registration_path, notice: "Connected as @#{connection.github_username}."
rescue ActiveRecord::RecordNotUnique
  redirect_to edit_user_registration_path,
              alert: "This GitHub account is already connected to a different hifumi.dev login."
end
```

Tests to add (`test/integration/github_oauth_test.rb`): a happy-path reconnect (current user's existing connection refreshes), a fresh-connect (no prior connection), and the conflict case (a different user already owns the `github_user_id`).

---

### Chat-on-new-project race: first assistant turn invisible until refresh

**File**: `app/controllers/projects_controller.rb:25` — current workaround in place: `ChatRespondJob.set(wait: 0.5.seconds).perform_later(first_message.id)`.

**Symptom (seen on prod 2026-05-15 right after the footer/cookie-consent deploy)**: user submits a new project description, lands on `/projects/:id`, but the assistant's "working…" placeholder + final response never appear. Manual refresh re-renders from DB and both show up. Reproduced twice in a row at hifumi.dev; never reproducible on `localhost`.

**Root cause** — Turbo Cable subscription cold-start race, exact timeline from prod Kamal log (see thread on 2026-05-15):
```
T=0.000s  POST /projects        → user message 141 created, ChatRespondJob enqueued
T=0.118s  redirect 302 → /projects/22
T=0.221s  GET /projects/22 starts
T=0.249s  GET /projects/22 returns   ← page renders, message 142 doesn't exist yet
T=0.262s  ChatRespondJob enqueues append broadcast for message 142 (placeholder)
T=0.280s  server performs append message 142            ← browser hasn't subscribed yet
T=0.377s  Turbo::StreamsChannel SUBSCRIBES to project's stream   ← 97ms too late
T=2.986s  ChatRespondJob enqueues `replace message_142` (LLM response)
          → no #message_142 in DOM → Turbo silently no-ops
```

The 500ms wait pushes the placeholder broadcast to ~T=0.762s, well past the ~T=0.377s WebSocket subscribe. Loopback connections subscribe in <10ms so the race is invisible locally.

**Why this is a workaround, not a fix**: 500ms is empirical, not principled. A slow client on a flaky connection might still miss the subscribe deadline; a fast cluster might make the wait visible as UX latency. The race also resurfaces if anyone shortens or removes the wait without realising.

**Real fixes, in order of cleanliness**:

1. **Create the assistant placeholder synchronously in `ProjectsController#create` before the redirect.** The show action then renders message 142 from the DB; only the eventual `replace` arrives via WebSocket — and the page's subscription happens during normal load, with plenty of time before the LLM responds. Tricky bit: per memory `project_ruby_llm_message_lifecycle.md`, RubyLLM's `acts_as_chat` auto-creates the assistant row inside `on_new_message`, so the controller-created row needs to be the same row RubyLLM populates. Plumbing: pass the placeholder's id into `ChatRespondJob`, and have the job pre-bind it onto the RubyLLM chat (or update the placeholder when `on_end_message` fires).

2. **One-shot reconciliation on `turbo:load`**: chat container Stimulus controller fetches `/projects/:id/messages.json` (or similar) once after page load, diffs against DOM, appends anything missing. Covers all flavours of this race, not just the new-project one. Slight extra request per page load.

3. **Investigate kamal-proxy `--buffer-responses` impact on `/cable` upgrade**: unlikely culprit (proxy detects Upgrade and passes through), but worth a 10-minute look — if the buffer flag adds even 50ms to the WebSocket handshake, removing it (or scoping to non-`/cable`) gives breathing room.

**MessagesController#create is unaffected** — that path doesn't redirect, the WebSocket subscription persists across the form-replace, broadcasts always arrive after subscription. Only `ProjectsController#create` has this race; the wait is scoped there.

**Triggering on `main`**: clear localStorage + cookies (anon), accept cookies, sign in, submit a new project. Without the wait you'll see no assistant response until you refresh. With the wait it consistently renders.

---

## 2026-06-11

### Post-launch review findings

A full robustness/OSS-readiness review of the production deployment was done; findings recorded in `docs/04-reviews/01-post-launch-review.md` (CVE'd gems plus the candidate Phase 5 directions). Actioned since: the codegen agent now runs in a per-instruction isolated container — see the residuals below.

### Per-project model selection — extension points

Shipped 2026-06-11 (`feature/per-project-model-selection`): per-stage model columns on profiles (user defaults) + projects (per-project snapshot), selectors in the build tab / new-project form / account integrations pane, threaded through all six LLM stages via `LLM::Stages` (`lib/llm/stages.rb`). Deliberately deferred:

- **Curated list is 3 Anthropic models.** `LLM::Stages::AVAILABLE_MODELS` is a hand-maintained hash. The dormant `models` table (`acts_as_model`, never populated) could back a full OpenRouter catalog picker instead — needs capability filtering per stage (`structured_outputs` for plan/template, `tools` for chat) and a refresh job hitting `GET openrouter.ai/api/v1/models`. See `thoughts/shared/research/2026-05-11/per-user-model-config-per-stage.md`.
- **Code/docs stages are Anthropic-only by transport.** They run through the `claude` CLI's Anthropic API surface (`bin/roast-openrouter`); non-Anthropic ids have never been exercised there. The "direct-API Roast provider" Phase 5 candidate would lift this.
- **No cost display.** The 2026-05-11 research scoped per-model pricing display next to each selector; AVAILABLE_MODELS would need pricing metadata (or the models table).

### Agent sandbox — residuals to follow up

The codegen agent now runs each revision in a per-instruction throwaway container (`Roast::Sandbox`, `lib/roast/sandbox.rb`) that mounts only that project's workspace and no Docker socket. Needs production verification (none of it runs on the macOS dev box) and has open follow-ups, in rough priority:

1. **Verify on the host.** Remaining: one full sandboxed generation green on the Linux host under the uniform-uid sandbox (`--user generator`, zero cap-adds — issue #24 replaced the earlier root+`runuser` design after the 2026-06-12 prod E2E hit the capless-root/mixed-uid SQLite deadlock). C1/C2 probes, gem resolution, and `HIFUMI_AGENT_IMAGE` pinning were confirmed on prod 2026-06-12.
2. **Generator-side Docker socket.** The generator container still runs `USER root` with `/var/run/docker.sock` bound — it has to, to launch throwaways + previews. The agent no longer runs there, but an RCE in the generator process itself is still host-root. Put a socket-proxy (e.g. tecnativa/docker-socket-proxy) in front, allowing only the `containers/images/networks` verbs PreviewManager + Sandbox use. (Already a Phase 5 candidate.)
3. **Agent egress is unrestricted.** The throwaway uses the default bridge (needs OpenRouter + rubygems). It can therefore also reach the host's published ports / other bridge containers. Move it to a dedicated network that allows only the egress it needs (DNS + 443 to OpenRouter + the gem source), or front gem installs with a local mirror so the network can be `--internal`.
4. **Bundle vendoring (perf).** The throwaway reconciles the app's gems via `AutoRemediate`'s `bundle install` on first verify, re-doing it per revision for agent-added gems. If first-revision wall time suffers (Step-7 budget is already near the edge), vendor the workspace bundle into `vendor/bundle` (already gitignored in the skeleton) so installed gems travel via the mount — but this requires untangling the `BUNDLE_PATH=/usr/local/bundle` global vs the workspace bundle (see the warning comment in `lib/roast/verify_revision.rb`), so it's deliberately deferred. (`/usr/local/bundle` is generator-owned since issue #24, so the uid-permission half of that tangle is gone; the perf half remains.)
5. **Dev/prod parity.** Sandboxing is prod-only; dev runs roast directly (no Docker, Claude-subscription transport). `FORCE_AGENT_SANDBOX=1` exercises the container path locally (needs Docker + `HIFUMI_AGENT_IMAGE` + an OpenRouter key) — wire it into CI or a manual smoke step once a Linux runner is available, since the macOS dev box can't run it.
