---
date: 2026-05-07T12:55:08+0200
researcher: Paweł Strzałkowski
git_commit: 153b944bb423086ab2dee978389df48c911fdefe
branch: main
repository: rails-app-generator
topic: "Exporting a generated app to GitHub: what exists today, what GitHub offers, what a procedure could look like"
tags: [research, github, export, oauth, github-app, octokit, git, share-with-user]
status: complete
last_updated: 2026-05-07
last_updated_by: Paweł Strzałkowski
---

# Research: Exporting a generated app to GitHub

**Date**: 2026-05-07T12:55:08+0200
**Researcher**: Paweł Strzałkowski
**Git Commit**: 153b944bb423086ab2dee978389df48c911fdefe
**Branch**: main
**Repository**: rails-app-generator

## Research Question

In `docs/09-ideas/01-git-integration.md` we mention that we could share the codebase with the user. Presumably we can export an application to GitHub and share it with the user — what can we do here, what procedure should we provide, and what do we need to do on the GitHub side (authenticate with GitHub?)? The user has very little prior exposure to this subject.

## Summary

Two halves to the answer:

1. **What we already have, on disk, today** — every generated app *is* a real, self-contained git repo with a baseline commit, a per-revision commit, and a per-revision docs commit. Workspaces sit at `~/projects/rails-app-generator-workspaces/project_<id>/`. We have a Devise-backed `User`, a `Project belongs_to :user`, and an existing per-user-secret pattern (`Profile#openrouter_api_key` via Rails 8 `encrypts`). We have **zero** network-facing git code (no `git push`, no Octokit, no `gh`, no GitHub OAuth). The `omniauth :github, …` line in `config/initializers/devise.rb` is commented out.

2. **What GitHub itself offers, in 2026** — two integration models (OAuth App and GitHub App). GitHub explicitly recommends **GitHub Apps** for new integrations. With a GitHub App we get user access tokens (`ghu_…`) that expire after 8 hours and refresh tokens (`ghr_…`) that last 6 months; with `Administration: write` + `Contents: write` scoped to the user's own account the app can create a repo and push to it. The realistic push mechanic is shelling out `git push https://x-access-token:TOKEN@github.com/owner/repo.git` — works with our existing `git` binary, no API choreography. Established players (bolt.new, Vercel, Replit) all use GitHub Apps with a "Connect to GitHub → install app once → one-click export from then on" UX.

The user explicitly asked "what can we do here?" and "what procedure should we provide?" — beyond pure as-is documentation, this report includes an outline of what the wired-up flow would look like. It is not a plan; it's the lay of the land.

## Detailed Findings

### Part A — Current state of the codebase

#### A1. Each workspace is already a git repo

`init_rails_app` in `app/jobs/execute_instruction_job.rb:70-77` runs `git init -q && git add -A && git commit -q -m 'chore: skeleton baseline'` inside `Bundler.with_unbundled_env`. Author identity is set inline at the commit call: `git -c user.email=generator@local -c user.name='Rails App Generator' commit ...`. There is **no** global git config set on the host — the identity is only attached to that one commit.

Each subsequent commit comes from one of:

- `app/jobs/execute_instruction_job.rb:148-149` — `'docs: scaffolding baseline'` (no explicit author flags; falls back to whatever global git config exists)
- `lib/templates/picker.rb:59-63` — `'docs: pick frontend template (<name>)'` (explicit author flags)
- `lib/roast/revision_workflow.rb:277` — message is the LLM-written `revision_summary` (no explicit author flags)
- `lib/roast/revision_workflow.rb:330-332` — `'docs: update manifest and revision notes'` (no explicit author flags)

Net effect: a finished revision produces ~2 commits (code commit + docs commit), and a fresh workspace produces ~3 baseline commits before the first instruction even runs. The HEAD SHA after each code commit is persisted on the `revisions.git_sha` column (see `db/schema.rb:133`).

> **Implication for export**: the history is *already meaningful*. We don't need to fabricate a synthetic history at export time — what we'd push is what the user already sees in the chat timeline.

#### A2. Workspace location and naming

`app/models/project.rb:17-18`:

```ruby
def workspace_path
  File.join(self.class.workspace_root, "project_#{id}")
end
```

Default root: `~/projects/rails-app-generator-workspaces`, overridable via `RAILS_APP_GENERATOR_WORKSPACE_ROOT`. `workspace_path` was once a DB column; migration `db/migrate/20260418151522_remove_workspace_path_from_projects.rb` removed it in favor of the derived method. Each `project_<id>/` is its own independent git repo (not a worktree, not a submodule).

#### A3. There is currently no network-facing git code

A repo-wide search confirms:

- No `git push`, `git remote add`, `gh ` invocations in `app/`, `lib/`, `config/`, or `bin/` source.
- No `octokit`, no `omniauth-github` in `Gemfile`.
- The single `github` mention in initializer code is `# config.omniauth :github, ...` (commented out) at `config/initializers/devise.rb:277`.
- The `gh` reference in `config/ci.rb:18-20` is a commented-out signoff example.

This is a clean slate: an export-to-GitHub feature would be net-new code, not a refactor of something in flight.

#### A4. User and per-user-secret pattern

We have a real auth system. `app/models/user.rb:2` uses Devise with the standard modules (`database_authenticatable`, `registerable`, `recoverable`, `rememberable`, `validatable`) — no OAuth providers wired up. `Project belongs_to :user` (`app/models/project.rb:2`, `db/schema.rb:125`), and `app/controllers/concerns/project_owner_required.rb` enforces ownership.

The per-user-secret pattern is already established by the OpenRouter BYOK flow:

- `Profile` is `has_one` off `User` with `autosave: true`.
- `app/models/profile.rb:4` — `encrypts :openrouter_api_key` (Rails 8 attribute encryption; the underlying column at `db/schema.rb:111` is a plain `string`).
- It's set via the Devise registration/edit forms (`users/registrations_controller.rb:44,49`) using `accepts_nested_attributes_for :profile`.
- Call sites read it as `project.user.profile.openrouter_api_key` — see `execute_instruction_job.rb:123,159`, `chat_respond_job.rb:8`, plus the two `CreatePlan::AdHocLLM` classes.

> **Implication for export**: a future `github_access_token`, `github_refresh_token`, `github_token_expires_at` triplet has an obvious home — either three more `encrypts` attributes on `Profile`, or a separate `GithubConnection has_one :user` model. The pattern of "per-user encrypted secret read off the `User`" is already load-bearing in three call sites; a fourth would not be unusual.

#### A5. Generated app's content — README and "this is generated" markers

- `lib/preview/skeleton/README.md` — vanilla `rails new` boilerplate. Copied verbatim into every workspace by `init_rails_app` at `execute_instruction_job.rb:38`.
- No `CLAUDE.md` is written into the skeleton.
- No file or git note explicitly says "this app was made by Rails App Generator."
- The `docs/` directory written into the workspace (`docs/architecture.md`, `docs/conventions.md`, `docs/domain.md`, `docs/revision_notes.md`, plus `docs/frontend.md` from the template picker) is the closest thing to a fingerprint — `rails new` does not produce these. They're written at `execute_instruction_job.rb:141-145` and `lib/templates/picker.rb:50-52`.

> **Implication for export**: the README that goes to GitHub today is the vanilla `rails new` README. The "generated README per app" idea from `docs/09-ideas/01-git-integration.md` would be a separate piece of work upstream of any push.

#### A6. Project model and lifecycle

`projects` columns (`db/schema.rb:117-127`): `id`, `name`, `user_id` (NOT NULL), `preview_state` (enum: stopped/starting/running/failed), `preview_container_id`, `preview_error`, `preview_started_at`, `created_at`, `updated_at`. No export-related columns.

Lifecycle as currently implemented:
1. `POST /projects` → `Project` created with `name` from the first chat message.
2. `ChatRespondJob` drives the chat agent → calls `create_application` / `modify_application` tools.
3. Each tool enqueues `ExecuteInstructionJob` per instruction.
4. `ExecuteInstructionJob` runs `prepare_workspace` → `init_rails_app` → `init_docs_baseline` → `pick_frontend_template` → loops `revisions` calling `run_roast_subprocess`.
5. Instruction transitions to `:completed` / `:failed`; UI updated via Turbo Streams.
6. Preview started/stopped independently via `PreviewManager` (mounts `workspace_path` as a Docker volume — see `preview_manager.rb:202,242`).

There is **no** export, archive, or "I'm done with this" step. Workspaces persist on disk indefinitely.

---

### Part B — What GitHub gives us to work with

#### B1. OAuth App vs GitHub App

GitHub explicitly recommends GitHub Apps for new integrations. The salient differences:

| Aspect | OAuth App | GitHub App |
|---|---|---|
| Token type | Classic `gho_…`, no expiry | User access `ghu_…` (8h) + refresh `ghr_…` (6mo); plus installation tokens for bot-mode |
| Repo scope shape | `repo` (broad) or `public_repo` | Fine-grained per-repo permissions (`Administration: write`, `Contents: write`, …) |
| Consent UX | One Authorize button, blanket access | "Install + Authorize" — user picks all repos or selected repos |
| Setup cost | Low (client ID/secret, no JWT) | Higher (private key, JWT signing, refresh logic) |
| Rate limit | 5 000 req/hr per user | 5 000 req/hr per user-token, scales for installation tokens |
| 2026 status | Legacy-but-supported | Recommended path |

For our exact use case ("create a repo in the user's account, push the workspace, walk away") **either works**. OAuth App is simpler to ship; GitHub App is the longer-term posture with tighter security and is what bolt.new / Vercel / Replit all use.

#### B2. Minimum scopes for "create + push + leave"

- **OAuth App**: `repo` (covers private + public). `public_repo` is enough if we only ever create public repos — narrower but still broad.
- **GitHub App**: `Administration: write` (to call `POST /user/repos`) **plus** `Contents: write` (to push commits). Both required.

There is no narrower scope that creates a repo. After creation, `Contents: write` alone suffices for git operations.

#### B3. Ruby libraries in scope

- **`octokit` v10.0.0** (April 2025, actively maintained). `Octokit::Client.new(access_token: token)` for both OAuth and GitHub App user tokens. No built-in OAuth dance helper.
- **`omniauth-github` v2.0.0** — handles the redirect/callback OAuth flow for OAuth Apps and the user-authorization leg of GitHub Apps (same `/login/oauth/authorize` endpoint). Returns auth hash with `credentials.token`. Does not handle GitHub App JWT signing or refresh.
- **No officially blessed Ruby GitHub App toolkit** (no equivalent of JS's `@octokit/app`). Refresh logic and JWT signing would be hand-rolled with the `jwt` gem if we go GitHub App.

#### B4. Push mechanics

Two real options once a token is in hand:

**Option A — shell out to `git push` (recommended for our stack)**

```bash
git -C <workspace_path> remote add origin \
  https://x-access-token:TOKEN@github.com/<owner>/<repo>.git
git -C <workspace_path> push origin main
```

- Handles binaries, full history, branches, tags.
- Works for any repo size up to GitHub's 2 GB push limit.
- Needs the `git` binary — already in our environment.
- `x-access-token` username + token-as-password works for both OAuth and GitHub App user tokens.
- Don't persist the token in the remote URL — pass it inline for one-shot or use a credential helper.

**Option B — Git Data API (blobs + trees + commits)**

Octokit-only path: `create_blob` → `create_tree` → `create_commit` → update ref. 100 MB hard per-file cap (50 MB recommended). Useful if we couldn't have a `git` binary; verbose and error-prone otherwise.

For our generated apps (small, mostly text, shallow history) Option A is the obvious choice.

#### B5. UX in the wild

- **bolt.new (StackBlitz)** — GitHub App; click GitHub icon → "Log in to GitHub" → "Authorize stackblitz" → from then on Bolt creates/updates repos automatically on save. Personal repos only as of early 2025.
- **Vercel** — GitHub App installed once per user/org; the same install powers project import and "Push to GitHub on first deploy."
- **Replit** — GitHub App; "Connect to GitHub" in the Version Control tab.
- **v0.dev (Vercel)** — reuses the Vercel GitHub App.

The shared shape: **GitHub App, one-time install, one-click export from then on**.

#### B6. Gotchas

- **Token revocation** — user can uninstall the app or revoke the OAuth grant at any time. Every API call can `401`. Catch `Octokit::Unauthorized` and re-prompt.
- **Token expiry (GitHub App)** — user access tokens last 8 hours. If the user clicks "Export" hours after authorizing, the token may be expired. Refresh before use.
- **SAML SSO orgs** — GitHub App user tokens obtained through the proper OAuth flow are auto-SAML-authorized. OAuth App tokens may need separate authorization. Not relevant for personal-account-only flows.
- **2FA** — does not affect API or git-over-HTTPS, only interactive web login.
- **Repo name collisions** — `POST /user/repos` returns `422`. Check existence first or suggest a fallback name (`-2`, timestamp).
- **File size caps** — single file > 100 MB blocked, > 50 MB warned. Total repo recommended < 1 GB. Generated Rails apps are tiny; not a real risk unless a user adds video assets.
- **Org repos** — different endpoint (`POST /orgs/{org}/repos`) and the user must be admin. Out of scope for v1.
- **Push to a non-empty repo** — fails on divergence. Don't `--force` unless we own the repo's whole life.

---

### Part C — The shape of a procedure (what user-facing flow could look like)

This part is forward-looking; the user explicitly asked for it. Concrete numbers and choices below are sketches, not commitments.

#### C1. One-time per-user wiring

1. Add a "Connect GitHub" entry to the user's profile/settings page (next to the existing OpenRouter API key field).
2. Clicking it sends the user through the GitHub App authorization flow (an `omniauth-github`-handled `/auth/github` redirect with the GitHub App's client ID).
3. On callback, the auth hash gives us `access_token`, `refresh_token`, `expires_at`, plus the GitHub username.
4. Persist on `Profile` (or a new `GithubConnection`) with `encrypts` for the tokens.
5. UI shows "Connected as @username — Disconnect" from then on.

#### C2. Per-project export action

1. "Export to GitHub" button appears on the project page once GitHub is connected and the project has at least one completed instruction.
2. Click → background job (Solid Queue):
   - Refresh user access token if `expires_at < Time.current + 1.minute`.
   - Octokit `create_repository(name, private: …, description: …)` — name defaults to project slug, user can override; collision → suggest `-2` or let user retry with a new name.
   - `git -C <workspace_path> remote add origin https://x-access-token:TOKEN@github.com/<owner>/<repo>.git`
   - `git -C <workspace_path> push origin main`
   - Strip the token-bearing remote: `git -C <workspace_path> remote set-url origin https://github.com/<owner>/<repo>.git` (so a leftover `.git/config` never leaks the token).
3. UI updates with the new GitHub URL plus clone instructions ("here's how to keep working on this locally").
4. Subsequent revisions can either be pushed automatically on each completed instruction (bolt.new style) or remain manual ("Push latest changes" button). v1 is probably manual; auto-push is a follow-up.

#### C3. What we'd want to write into the repo before pushing

These are upstream of the push, not part of the GitHub integration itself:

- A generator-aware `README.md` (replace the vanilla skeleton README) — what the app is, gem choices, run-locally instructions. Already listed in `docs/09-ideas/01-git-integration.md` lines 27–28.
- Optionally a `CLAUDE.md` for users who want to continue with Claude Code (also in the idea doc, line 28).
- Verify the existing per-revision commit messages survive the push intact — they do (it's a normal git repo).
- Possibly a final "polish" commit at export time, or a tag for "v0-exported".

#### C4. What we don't need to do for v1

- No webhooks (we're not subscribing to GitHub events).
- No bot-mode (installation token) flows — everything is user-token.
- No Linear / Slack / GitLab analogues.
- No PR-based export (just push to the default branch).

---

## Code References

- `app/jobs/execute_instruction_job.rb:38` — copies `lib/preview/skeleton/` into workspace
- `app/jobs/execute_instruction_job.rb:70-77` — `git init` + first commit (`'chore: skeleton baseline'`) with explicit author
- `app/jobs/execute_instruction_job.rb:141-145` — writes `docs/architecture.md` etc. into workspace
- `app/jobs/execute_instruction_job.rb:148-149` — `'docs: scaffolding baseline'` commit (no explicit author)
- `app/jobs/execute_instruction_job.rb:123,159` — reads `project.user.profile.openrouter_api_key`
- `lib/templates/picker.rb:50-52` — writes `docs/frontend.md`
- `lib/templates/picker.rb:59-63` — `'docs: pick frontend template (<name>)'` commit (explicit author)
- `lib/roast/revision_workflow.rb:277` — code commit using LLM `revision_summary` as message
- `lib/roast/revision_workflow.rb:330-332` — `'docs: update manifest and revision notes'` commit
- `app/models/project.rb:2` — `belongs_to :user`
- `app/models/project.rb:17-18` — `workspace_path` derivation
- `app/models/project.rb:61-63` — `workspace_root` env override
- `app/models/profile.rb:4` — `encrypts :openrouter_api_key` (the per-user-secret pattern to mirror)
- `app/models/user.rb:2` — Devise modules in use
- `app/controllers/concerns/project_owner_required.rb` — ownership enforcement
- `db/schema.rb:111` — `profiles.openrouter_api_key` column (encrypted via Rails 8 attr encryption)
- `db/schema.rb:117-127` — `projects` columns
- `db/schema.rb:125` — `projects.user_id NOT NULL`
- `db/schema.rb:133` — `revisions.git_sha`
- `db/migrate/20260418151522_remove_workspace_path_from_projects.rb` — workspace path moved to method
- `db/migrate/20260429102931*.rb` — Project ownership added
- `config/initializers/devise.rb:277` — commented-out `config.omniauth :github, ...`
- `lib/preview/skeleton/README.md` — vanilla skeleton README (copied verbatim into every workspace)
- `lib/preview/preview_manager.rb:202,242` — Docker volume mount of `workspace_path`

## Architecture Documentation

The architecture-relevant facts that any export feature would slot into:

- **Each workspace is its own real git repo, with meaningful per-revision commits.** Export is "push what's already there," not "synthesize a history."
- **Per-user secret encryption pattern is already established** via Rails 8 `encrypts` on `Profile#openrouter_api_key`. GitHub tokens fit the same pattern.
- **All long-running work runs through Solid Queue jobs** with Turbo Stream broadcasts to update the UI. An export job would follow the same shape (this matches the `execute_instruction_job.rb` and `preview_manager.rb` patterns).
- **`Project belongs_to :user`** is enforced via the `ProjectOwnerRequired` concern. Export would naturally enforce the same.
- **Workspace path is a derived method, not a column.** Any export job receives `project.id` and re-derives the path; it does not need an extra column.
- **The `git` binary is available in the environment** (used by `execute_instruction_job.rb`, `revision_workflow.rb`, `templates/picker.rb`). Shell-out push is a natural fit; no new container dependency.

## Historical Context (from thoughts/)

No prior research documents in `thoughts/shared/research/` cover GitHub export, OAuth, or repo sharing — this is a greenfield investigation. The only adjacent material is `docs/09-ideas/01-git-integration.md` itself, which lists "Push to GitHub — OAuth, new repo, full commit history" as an idea with no further specification.

The Phase 5 candidates memory (`project_phase_5_candidates_after_4d.md`) does not mention export-to-GitHub as a current candidate — meaning shipping this would be a new sequencing decision, not the activation of something already queued.

## Related Research

None — this is the first research document on the topic.

## Open Questions

1. **OAuth App vs GitHub App for v1** — OAuth App ships in days (one Devise/omniauth wiring, no JWT), GitHub App is the long-term posture (refresh + fine-grained scopes + matches industry norms). Trade-off: ship-now vs ship-once-correctly.
2. **Auto-push every revision vs. manual "Export now" button** — bolt.new auto-pushes; that requires every revision to leave the system in a pushable state. Manual is the safer v1.
3. **Generator-aware README + CLAUDE.md** — listed in the idea doc but not built. The pre-export "polish" pass that writes them is a separate piece of work; sequencing matters (do we want "Export to GitHub" to ship before or after "Generated apps have a real README"?).
4. **Org repos vs personal-only** — every comparable product starts personal-only. Confirm that's the v1 cut.
5. **Where do GitHub tokens live** — additional `encrypts` attributes on `Profile`, or a new `GithubConnection has_one :user` model. The `Profile` route is faster; the dedicated-model route is cleaner if more providers (GitLab, Bitbucket) follow.
6. **Token-leak hygiene at push time** — confirm we strip the token-bearing remote URL after the one-shot push so it never lands in `.git/config` on disk.
7. **Re-export semantics** — what happens when a user clicks "Export" twice? Same repo, force-with-lease? Suggest a new name? Refuse?
