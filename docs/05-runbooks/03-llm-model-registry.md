# Runbook 03 — LLM model registry (seed + verify)

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
serves a store that is entirely empty.

The store is therefore **seeded**: `db/seeds.rb` writes one row per
`LLM::Stages::AVAILABLE_MODELS` id under `LLM::Stages::PROVIDER`
(`openrouter`), and `test/fixtures/ruby_llm_models.yml` derives the test store
from the same hash. An empty store, or a store missing an offered id, is a
setup error — `bin/verify-model-registry` exits 1 on either.

Every RubyLLM call site also passes `provider: LLM::Stages::PROVIDER`. Left
implicit, RubyLLM ranks candidate rows by its own `PROVIDER_PREFERENCE`, where
`perplexity` outranks `openrouter`; both catalogues list the dot-less 5-series
ids (`anthropic/claude-sonnet-5`, `anthropic/claude-opus-5`), so a store that
ever carries both providers' rows — a refreshed one does — would hand those
chats to Perplexity and die with `ConfigurationError`.

Affected stages are the four RubyLLM-backed ones (chat, plan_creation,
plan_modification, template). `code` and `docs` are unaffected: they pass the id
to the `claude` CLI as `--model`, with no registry lookup.

**Symptoms**: `RubyLLM::ModelNotFoundError`. On chat it surfaces as the friendly
banner *"The configured model is unavailable. Contact the operator."*
(`ChatRespondJob::FRIENDLY_ERRORS`); on the template stage `ExecuteInstructionJob`
has no rescue, so the job fails into Solid Queue.

`bin/rails db:seed` is the fix. It is idempotent (`find_or_create_by!` on
`provider` + `model_id`), offline, and five upserts — no network, no write-lock
window. Bare rows (`model_id`, `provider`, `name`) are all RubyLLM needs to
resolve a chat; see the optional section below for metadata.

## Local

```bash
bin/rails db:seed && bin/verify-model-registry
```

No restart needed for the check — `bin/verify-model-registry` is a fresh
process. Restart `bin/dev` afterwards: the running Puma and worker memoise the
registry per process.

## Production

```bash
# 1. Baseline (read-only)
kamal app exec --reuse "bin/rails runner 'puts RubyLLM::ActiveRecord::Model.count'"

# 2. Seed (idempotent — safe on the populated store; adds only missing offered ids)
kamal app exec --reuse "bin/rails db:seed"

# 3. Verify
kamal app exec --reuse "bin/verify-model-registry"

# 4. Restart — required if step 2 added a row; see the warning below
V=$(kamal app version | sed -n '2p')   # line 2: kamal prints "App Host:" first, and tail -1 is blank
kamal app stop
kamal app start --version="$V"
```

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

**Cheapest path**: pair the seed with a deploy. `kamal deploy` recreates
containers anyway, so the restart comes free and step 4 disappears. Running
`db:seed` *before* the deploy is fine too — the old code ignores the extra row.

## Optional: enrich metadata with `RubyLLM.models.refresh`

Seeded rows are bare: `context_window`, `max_output_tokens`, `pricing` and
`capabilities` are empty, and `bin/verify-model-registry` prints `ctx=?` for
them. Nothing on hifumi's paths reads those fields — the request's
`max_output_tokens` comes from `Chat#with_max_output_tokens`, never from the
registry row, and no view or job reads cost or context window. Refresh only
when that metadata is wanted.

`RubyLLM.models.refresh` fetches the published registry
(`rubyllm.com/models.json`), merges per-provider discovery over it, and persists
through the store with `find_or_initialize_by(model_id:, provider:) + update!`
inside a transaction, so seeded rows are enriched in place. Prefer it over
`bin/rails ruby_llm:load_models`, which only reloads the *bundled* JSON and so
lags the live catalogue.

**It is failure-safe.** Per-provider fetches are rescued individually into a
`failed` list (`models.rb:151-164`); models belonging to a failed provider are
carried over unchanged and the failure is logged *"Keeping existing."*
(`:222-230`). A models.dev outage degrades the same way.

```bash
# Local
bin/rails runner 'RubyLLM.models.refresh; puts RubyLLM::ActiveRecord::Model.count'

# Production — run during a quiet window: refresh wraps every row in ONE
# transaction, and v2 fetches every provider's registry (1464 rows, not v1's
# 410). That holds the write lock on production.sqlite3 while users are
# chatting, and config/database.yml sets timeout: 5000 — a chat write that
# waits longer than 5s raises SQLite3::BusyException.
kamal app exec --reuse "bin/rails runner 'RubyLLM.models.refresh; puts RubyLLM::ActiveRecord::Model.count'"
```

A `WARN … Failed to fetch models.dev (ArgumentError: argument out of range)` line
is expected and harmless: that fetch only enriches metadata, and the OpenRouter
provider fetch is what carries the ids.

No `OPENROUTER_API_KEY` is needed. The container has no global key (BYOK is
per-user), so the provider sends the placeholder from
`config/initializers/ruby_llm.rb` as its bearer token — and OpenRouter's
`/api/v1/models` returns 200 regardless of auth. Do **not** pass a real key
inline: kamal echoes the full `docker exec` command into its own log output.

A refresh grows the store to every provider's catalogue, which is exactly the
state the `provider:` pin exists for. **At 2.0.0.rc3 and rc4 a refresh also deletes**
rows absent from the refreshed registry (`Model.save_to_database` ends in
`unlist`); a row a chat's `ruby_llm_model_id` references is kept and stamped
`unlisted_at` instead, and RubyLLM ranks unlisted rows last — harmless only
because every call site pins `LLM::Stages::PROVIDER`. So follow a refresh with
`bin/rails db:seed` (restores any offered id the refresh removed) and
`bin/verify-model-registry`, then restart.

## Adding a model to the picker

1. **Confirm the slug and its capabilities on the provider:**
   ```bash
   curl -s https://openrouter.ai/api/v1/models \
     | jq -r '.data[] | select(.id|startswith("anthropic/")) | .id' | sort
   curl -s https://openrouter.ai/api/v1/models \
     | jq -r '.data[] | select(.id=="anthropic/claude-opus-5") | .supported_parameters'
   ```
   `structured_outputs` is required for the plan and template stages, `tools` for
   chat. Use the full OpenRouter slug (dotted, e.g. `anthropic/claude-sonnet-4.6`)
   — never the `claude` CLI's short aliases, which OpenRouter rejects. On a
   *refreshed* store (dev, 1464 rows) `bin/verify-model-registry <slug>` doubles
   as a slug check — it resolves only if OpenRouter's catalogue carried it at the
   last refresh. On a seeded-only store a candidate always fails; that is expected.

2. **Add the id + label to `LLM::Stages::AVAILABLE_MODELS`** (`lib/llm/stages.rb`).
   Nothing else is needed for it to appear in all three selectors — the build-tab
   pane, the new-project form, and the account integrations pane all render from
   the registry via `model_select_options`.

3. **`bin/rails test`.** The test fixture derives from `AVAILABLE_MODELS`, so
   `test/lib/llm/stages_test.rb` asserts the new id resolves from the store with
   no fixture edit.

4. **Deploy, then seed production and restart** (sections above) — or seed
   before the deploy; the old code ignores the extra row. Locally,
   `bin/rails db:seed && bin/verify-model-registry` and restart `bin/dev`.

5. **Only if a stage default changes**: a migration altering the column defaults
   on both `projects` and `profiles`, plus `test/lib/llm/stages_test.rb` (it
   asserts registry defaults == `column_defaults`) and the controller/job tests
   that hardcode ids.

## Standing caveats

- **Local dev codegen ignores per-project selection by design.**
  `bin/roast-claudesubscription` gets the bare aliases `sonnet` (code) and
  `haiku` (docs), so the model that actually runs is whatever the operator's
  `claude` CLI resolves those to. Use `FORCE_OPENROUTER=1` to exercise selection
  (runbook 01, level 2).
- **Removing a model** from `AVAILABLE_MODELS` does not migrate rows already
  holding it. The inclusion validator re-runs across all six columns on every
  `Project`/`Profile` save, so a stale stored id blocks otherwise unrelated saves.

## Recorded baseline

**2026-09-18** (PR A deployed, release `f915863`, still on the git pin) — the
production store held **410 rows** before and after: `bin/verify-model-registry`
resolved all five offered ids under `openrouter`, and a `bin/rails db:seed` run
as the idempotency proof added nothing. No refresh was run.

**2026-08-23** (post-v2, local) — the upgrade migration carried the 410 rows
over to `ruby_llm_models` unchanged, and the first `RubyLLM.models.refresh`
under v2 took the store to **1464 rows**. The jump is expected and is the one
number that changed meaning: v1's refresh only wrote what OpenRouter discovery
returned, while v2 fetches the *published* registry (`rubyllm.com/models.json`,
every provider) and merges provider discovery over it. Two consequences when
comparing counts: the **migration** preserves the row count exactly, a
**refresh** grows it — so attribute any change to whichever step you just ran.
`PRAGMA foreign_key_check` stayed empty across both; at that pin a refresh never
deleted rows (it does at 2.0.0.rc3 and rc4 — see the enrichment section).

**2026-08-12** (pre-v2, when the table was still `models`) — both environments
were found holding a single row
(`openrouter anthropic/claude-haiku-4.5`), with `anthropic/claude-sonnet-4.6` and
`anthropic/claude-opus-4.6` raising `ModelNotFoundError`. After a refresh:
410 rows in each, all three offered ids resolving, and
`anthropic/claude-opus-5` / `-sonnet-5` / `-fable-5` resolving as candidates
(1M context each). Production restarted at version
`8227807c4fadb99a83638e9c2367491cf2122d21`.
