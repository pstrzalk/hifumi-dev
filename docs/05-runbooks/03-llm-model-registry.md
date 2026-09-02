# Runbook 03 — LLM model registry (populate + verify)

Keeps RubyLLM able to resolve every model `LLM::Stages` offers, and is the
procedure for adding a new model to the picker.

## Why this is needed

RubyLLM owns its model registry and stores it in the `ruby_llm_models` table.
The gem's railtie wires `config.model_registry_store` to
`RubyLLM::ActiveRecord::Model` whenever ActiveRecord loads, and
`Models.load_models` reads that store first, falling back to the gem's bundled
`models.json` **only when the table is empty** (`ruby_llm/models.rb:85-97`,
logging *"Model registry store is empty, falling back to the registry file"*).

So the store wins whenever it holds any rows at all: a **non-empty store
shadows the bundle completely**, and an id missing from it raises
`ModelNotFoundError` even when the bundle carries that id. The bundle only ever
serves a store that is entirely empty — which is also why a fresh environment
self-poisons, since each successful resolution writes one row back.

Affected stages are the four RubyLLM-backed ones (chat, plan_creation,
plan_modification, template). `code` and `docs` are unaffected: they pass the id
to the `claude` CLI as `--model`, with no registry lookup.

**Symptoms**: `RubyLLM::ModelNotFoundError`. On chat it surfaces as the friendly
banner *"The configured model is unavailable. Contact the operator."*
(`ChatRespondJob::FRIENDLY_ERRORS`); on the template stage `ExecuteInstructionJob`
has no rescue, so the job fails into Solid Queue.

`RubyLLM.models.refresh!` is the fix. It fetches the published registry
(`rubyllm.com/models.json`), merges per-provider discovery over it, and persists
through the store with `find_or_initialize_by(model_id:, provider:) + update!`
inside a transaction — **no deletes**, so `chats.ruby_llm_model_id` foreign keys
survive. Use it rather than `bin/rails ruby_llm:load_models`, which only reloads
the *bundled* JSON and so lags the live catalogue.

**It is failure-safe.** Per-provider fetches are rescued individually into a
`failed` list (`models.rb:151-164`); models belonging to a failed provider are
carried over unchanged and the failure is logged *"Keeping existing."*
(`:222-230`). A models.dev outage degrades the same way. So a refresh can only
add or update rows, never empty the registry — which is why production needs no
real OpenRouter key for this (see below).

## Local

```bash
bin/rails runner 'RubyLLM.models.refresh!; puts RubyLLM.config.model_registry_store.count'
bin/verify-model-registry
```

No restart needed — `bin/rails runner` is a fresh process, and `bin/dev` picks
the table up on next boot.

A `WARN … Failed to fetch models.dev (ArgumentError: argument out of range)` line
is expected and harmless: that fetch only enriches metadata, and the OpenRouter
provider fetch is what populates the ids.

## Production

```bash
# 1. Baseline (read-only)
kamal app exec --reuse "bin/rails runner 'puts RubyLLM.config.model_registry_store.count'"

# 2. Populate
# Run this during a quiet window: refresh! wraps every row in ONE transaction,
# and v2 fetches every provider's registry (1464 rows, not v1's 410). That holds
# the write lock on production.sqlite3 while users are chatting, and
# config/database.yml sets timeout: 5000 — a chat write that waits longer than
# 5s raises SQLite3::BusyException.
kamal app exec --reuse "bin/rails runner 'RubyLLM.models.refresh!; puts RubyLLM.config.model_registry_store.count'"

# 3. Verify. bin/verify-model-registry only exists in the image once it has been
#    deployed; until then use the inline equivalent below.
kamal app exec --reuse "bin/verify-model-registry"
kamal app exec --reuse "bin/rails runner 'LLM::Stages::AVAILABLE_MODELS.keys.each { |id| begin; RubyLLM::Models.resolve(id); puts %(OK   #{id}); rescue => e; puts %(FAIL #{id} #{e.class}); end }'"

# 4. Restart — required; see the warning below
V=$(kamal app version | sed -n '2p')   # line 2: kamal prints "App Host:" first, and tail -1 is blank
kamal app stop
kamal app start --version="$V"
```

No `OPENROUTER_API_KEY` is needed. The container has no global key (BYOK is
per-user), so the provider sends the placeholder from
`config/initializers/ruby_llm.rb` as its bearer token — and OpenRouter's
`/api/v1/models` returns 200 regardless of auth. Even if it did not, the refresh
degrades gracefully rather than emptying the store (see above). Do **not** pass a
real key inline: kamal echoes the full `docker exec` command into its own log
output.

Step 4 is required because `RubyLLM::Models.instance` is memoized per process
(`@instance ||= new`); the running Puma keeps the stale registry until replaced.
`SOLID_QUEUE_IN_PUMA: true` and a single `web` role mean one container restart
covers both web and jobs.

> ⚠️ **`kamal app start` needs `--version`.** Bare `kamal app start` looks for a
> container named `hifumi-dev-web-` (unversioned), fails to match the real
> versioned container, and leaves the site down — this happened on 2026-08-12
> and cost ~3 minutes of downtime. Capture the version first, as above, or
> recover with
> `kamal app start --version=$(kamal app containers | grep 'hifumi-dev-web-[0-9a-f]' | head -1 | sed 's/.*hifumi-dev-web-//')`.
> `kamal app restart` does not exist in this Kamal version. `kamal app boot`
> reboots but *recreates* the container, re-sourcing `.kamal/secrets` from the
> caller's shell — see the secrets-sourcing hazard before using it.

**Cheapest path**: pair the refresh with a deploy. `kamal deploy` recreates
containers anyway, so the restart comes free and step 4 disappears.

## Adding a model to the picker

Order is fixed — registry first, picker second. A model offered but unresolvable
raises the moment a user selects it.

1. **Confirm the slug and its capabilities on the provider:**
   ```bash
   curl -s https://openrouter.ai/api/v1/models \
     | jq -r '.data[] | select(.id|startswith("anthropic/")) | .id' | sort
   curl -s https://openrouter.ai/api/v1/models \
     | jq -r '.data[] | select(.id=="anthropic/claude-opus-5") | .supported_parameters'
   ```
   `structured_outputs` is required for the plan and template stages, `tools` for
   chat. Use the full OpenRouter slug (dotted, e.g. `anthropic/claude-sonnet-4.6`)
   — never the `claude` CLI's short aliases, which OpenRouter rejects.

2. **Refresh the registry** in every environment (sections above), then confirm
   the candidate resolves before offering it:
   ```bash
   bin/verify-model-registry anthropic/claude-opus-5
   ```

3. **Add the id + label to `LLM::Stages::AVAILABLE_MODELS`** (`lib/llm/stages.rb`).
   Nothing else is needed for it to appear in all three selectors — the build-tab
   pane, the new-project form, and the account integrations pane all render from
   the registry via `model_select_options`.

4. **Only if a stage default changes**: a migration altering the column defaults
   on both `projects` and `profiles`, plus `test/lib/llm/stages_test.rb` (it
   asserts registry defaults == `column_defaults`) and the controller/job tests
   that hardcode ids.

5. **After a `ruby_llm` gem bump**: re-run the refresh. The bundled `models.json`
   is what the *test* environment resolves against, and it lags the live catalogue.

## Standing caveats

- **Test environment** has an empty `ruby_llm_models` table, so it falls back to
  the bundled JSON. At the pinned `c45ebd78` that bundle carries
  `anthropic/claude-sonnet-5` but **not** `anthropic/claude-opus-5`, and no test
  resolves either. Stub `ctx.chat` in new tests rather than resolving a
  5-family id for real.
- **Local dev codegen ignores per-project selection by design.**
  `bin/roast-claudesubscription` gets the bare aliases `sonnet` (code) and
  `haiku` (docs), so the model that actually runs is whatever the operator's
  `claude` CLI resolves those to. Use `FORCE_OPENROUTER=1` to exercise selection
  (runbook 01, level 2).
- **Removing a model** from `AVAILABLE_MODELS` does not migrate rows already
  holding it. The inclusion validator re-runs across all six columns on every
  `Project`/`Profile` save, so a stale stored id blocks otherwise unrelated saves.

## Recorded baseline

**2026-08-23** (post-v2, local) — the upgrade migration carried the 410 rows
over to `ruby_llm_models` unchanged, and the first `RubyLLM.models.refresh!`
under v2 took the store to **1464 rows**. The jump is expected and is the one
number that changed meaning: v1's refresh only wrote what OpenRouter discovery
returned, while v2 fetches the *published* registry (`rubyllm.com/models.json`,
every provider) and merges provider discovery over it. Two consequences when
comparing counts: the **migration** preserves the row count exactly, a
**refresh** grows it — so attribute any change to whichever step you just ran.
`PRAGMA foreign_key_check` stayed empty across both, confirming the no-deletes
claim above against real `chats.ruby_llm_model_id` rows.

**2026-08-12** (pre-v2, when the table was still `models`) — both environments
were found holding a single row
(`openrouter anthropic/claude-haiku-4.5`), with `anthropic/claude-sonnet-4.6` and
`anthropic/claude-opus-4.6` raising `ModelNotFoundError`. After a refresh:
410 rows in each, all three offered ids resolving, and
`anthropic/claude-opus-5` / `-sonnet-5` / `-fable-5` resolving as candidates
(1M context each). Production restarted at version
`8227807c4fadb99a83638e9c2367491cf2122d21`.
