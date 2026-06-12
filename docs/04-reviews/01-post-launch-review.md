# Post-launch review — 2026-06-11

Snapshot review of the production deployment ~4 weeks after Phase 4 closed (2026-05-15). Scope: dependency state, robustness, test health, and open-source readiness. Findings are tracked for Phase 5 planning; the agent-isolation work discussed here has since been actioned (the codegen agent now runs in a per-instruction isolated container — `Roast::Sandbox`, `lib/roast/sandbox.rb`).

**State at review**: Phases 1–4 closed. All post-Phase-4 commits were design/UX polish (mobile pass, button system, dashboard, account page, footer/privacy/cookie consent), the hifumi.dev rename, and open-source prep (MIT license, README, CI). None of the Phase 5 candidates shipped; no Phase 5 plan doc exists. `bin/rails test`: 462 runs, 1736 assertions, 0 failures, 0 errors, 2 skips (the env-gated E2E tests). Brakeman: 4 warnings, all false positives (argv-form subprocess calls; two in `spikes/`).

---

## High

### R2 — High-severity CVEs in security-relevant gems (stale Gemfile.lock)

From `bundle exec bundler-audit` (2026-06-11):

| Gem | Version | Severity | Issue |
|---|---|---|---|
| oauth2 | 2.0.18 | High | GHSA-pp92-crg2-gfv9 — protocol-relative redirect leaks bearer `Authorization` to attacker host. This sits behind Sign in with GitHub. Fix ≥ 2.0.22 |
| puma | 8.0.0 | High ×2 | CVE-2026-47736 / -47737 — PROXY-protocol v1 remote memory exhaustion; app runs behind kamal-proxy. Fix ≥ 8.0.2 |
| jwt | 3.1.2 | High | CVE-2026-45363 — empty-key HMAC bypass |
| erb | 6.0.3 | High | CVE-2026-41316 — deserialization guard bypass |
| nokogiri | — | High | CSS-selector tokenizer ReDoS + XSLT memory leak |
| devise | 5.0.3 | Medium | CVE-2026-40295 — open redirect via `request.referrer` |
| faraday | 2.14.1 | Medium | host-scoping bypass (HTTP layer for Octokit + OpenRouter) |

Cheapest meaningful action in this whole document: `bundle update oauth2 puma devise jwt erb nokogiri faraday`, suite is green to verify against. (Several of these are already in-flight as Dependabot PRs.)

---

## Verified safe (guards confirmed — don't re-audit from scratch)

- **Command injection via chat prompts**: `revision.summary` / `revision.prompt` reach the roast subprocess as a frozen argv array via `Open3.popen3(env, *args)` (`execute_instruction_job.rb`) — no shell. Downstream shell uses (`revision_workflow.rb` git commit, picker) are `Shellwords.escape`'d or enum-validated.
- **Path traversal**: workspace paths derive from the integer PK (`project_#{id}`); no user string reaches a filesystem path or container name.
- **Authorization**: every project-scoped controller enforces ownership (`ProjectOwnerRequired` on messages/previews/github_exports; `ProjectsController` re-checks `user_id`; `index` scopes to `current_user.projects`). No raw-id fetch without an ownership check found.
- **BYOK key handling**: decrypted via AR `encrypts`, passed only as ENV (never argv → no `ps` leak), `LogScrub` redacts `sk-or-` from subprocess output and job error logs.
- **Agent execution**: the codegen agent runs each revision in a per-instruction throwaway container (`Roast::Sandbox`) that mounts only that project's workspace and no Docker socket — single-tenant by construction. Needs the host verification listed in `docs/09-ideas/05-followups.md`.
- **Preview isolation (prod)**: `--cap-drop=ALL`, `no-new-privileges`, `--read-only`, memory/cpu/pids caps, `--network=preview-internal` created with `--internal` in remote mode — egress-blocked, no host port mapping.
- **False alarm, verified**: `.env` is git-ignored (`.gitignore:11`), not tracked, never in history on any branch. Only `.env.example` and the comments-only `.kamal/secrets` are committed.

## Robustness notes

- No TODO/FIXME/HACK markers in `app/` or `lib/`.
- **Generation pipeline is not idempotent** (known — see CLAUDE.md `terminated_at` caveat): if `ExecuteInstructionJob` retries after a partial run, revisions re-execute against an already-mutated workspace. Preview start/stop *is* idempotent.
- Rescue-and-swallow sites are deliberate and documented (`PreviewManager.reset_orphans!`, boot reconciliation). No generation failure is silently swallowed — W2.F resets the workspace and the job marks the instruction `:failed`.

## Open-source readiness

Good: MIT LICENSE, contributor-facing README (mission, pipeline diagram, CLI entry points, contributing section), full CI (Brakeman + bundler-audit + importmap audit + RuboCop + tests + system tests), Dependabot, navigable docs tree, no secrets or personal content in the tree (operator email in `deploy.yml` is intentional `/privacy` disclosure).

Missing for a credible "learn how to build a Rails generator" repo:

- `CONTRIBUTING.md` (only an inline README section exists), `CODE_OF_CONDUCT.md`, GitHub issue/PR templates.
- The gated E2E generator test is broken (matches a fixture instead of the created instruction — see `docs/09-ideas/05-followups.md` 2026-05-14). It is the only end-to-end safety net; any "follow along" reader who runs it gets a false signal.
- Minor sanitization: local `/Users/pawel/...` paths in `spikes/roast/tmp/` logs.

## Candidate directions discussed (decision deferred)

Recorded so the next planning session doesn't start from zero. Four tracks, in tension:

1. **Harden for real multi-tenant users** — agent workspace isolation (done — `Roast::Sandbox`) + prompt-intake moderation as a proper Phase 5.
2. **Repo as teaching artifact** — architecture walkthrough docs, CONTRIBUTING, annotated reading paths, good first issues, fix the E2E test.
3. **External content** — articles / talks built on this codebase (Rails World angle: new builders Rails could gain).
4. **In-product education** — the `01-git-integration.md` ideas (diff view, annotated commits, "explain this change").

Quick wins independent of direction: R2 `bundle update`.
