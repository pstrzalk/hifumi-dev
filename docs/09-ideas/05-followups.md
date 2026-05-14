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
