# Runbook 04 — RubyLLM v2 production rollout

Deploy the RubyLLM 2.0 upgrade to hifumi.dev, and recover if it goes wrong.

## Why this needs a runbook

The upgrade migration **renames tables in place and has no `down`**
(`db/migrate/20260822224622_add_ruby_llm_v2_0_columns.rb` — `raise
ActiveRecord::IrreversibleMigration`). And it runs **by itself**:
`bin/docker-entrypoint:4-5` runs `db:prepare` whenever the command is
`./bin/rails server`, so **`kamal deploy` is what triggers it**. There is no
manual gate between deploying and migrating.

Two consequences drive every step below:

1. **The snapshot happens before the deploy, not after.** Once containers boot,
   the old schema is gone.
2. **Rollback is code *and* data.** The pre-upgrade image cannot read
   `ruby_llm_models` / `ruby_llm_tool_calls`, and the upgraded image cannot read
   `models` / `tool_calls`. Restoring one without the other leaves production
   broken either way.

## The WAL constraint

`config/database.yml` sets no `journal_mode`, so Rails 8's SQLite adapter runs
WAL — verified locally: `PRAGMA journal_mode` returns `wal`, and
`storage/production.sqlite3-wal` / `-shm` sit beside the database file.

- **Snapshots are safe on a live database.** `.backup` uses SQLite's online
  backup API and writes **one self-contained file, no sidecars** (verified:
  a `.backup` of a live WAL database produced exactly one file).
- **Restores are not.** Copying a file back while SQLite holds it open leaves
  the *other* database's WAL in place, and the next open replays it onto the
  file you just restored.

So: every restore in this runbook **stops the process first and deletes the
`-wal` / `-shm` sidecars**. No exceptions, including the local rehearsal.

`sqlite3` is available inside the container — it is installed in the Dockerfile's
`base` stage (`Dockerfile:22`), which the runtime stage inherits (`Dockerfile:110`).
Verified in the built image: `sqlite3 3.46.1`.

## 1. Rehearse locally on production data

The only way to know the migration survives real rows. Do this before the deploy,
not as a formality.

```bash
# 1.1 Snapshot production's primary database. Only the primary needs it:
#     cache/queue/cable are separate databases with their own migrations_paths
#     (config/database.yml), and the upgrade migration lives in db/migrate.
kamal app exec --reuse \
  "sqlite3 /rails/storage/production.sqlite3 \".backup '/rails/storage/production.sqlite3.pre-v2'\""

# 1.2 Copy it down. Reading straight off the volume needs no running container.
ssh root@77.42.95.154 "docker run --rm -v hifumi_dev_storage:/s -v /tmp:/out alpine \
  cp /s/production.sqlite3.pre-v2 /out/production.sqlite3.pre-v2"
scp root@77.42.95.154:/tmp/production.sqlite3.pre-v2 /tmp/production.sqlite3.pre-v2

# 1.3 STOP bin/dev. Everything below swaps the primary database file out from
#     under Rails, and a running Puma/Solid Queue holds an open WAL.

# 1.4 Park your own dev database, then move the snapshot into its place.
#     hifumi is multi-database, so DATABASE_URL cannot reliably point one
#     command at one file — swapping the primary's file is unambiguous.
#     Drop the sidecars after each copy: they belong to the file being
#     replaced, not to the one arriving.
sqlite3 storage/development.sqlite3 ".backup 'storage/development.sqlite3.mine'"
cp /tmp/production.sqlite3.pre-v2 storage/development.sqlite3
rm -f storage/development.sqlite3-wal storage/development.sqlite3-shm

# 1.5 Record the before counts, migrate (TIMED), record the after counts.
sqlite3 storage/development.sqlite3 "SELECT COUNT(*) FROM models;"          # before
sqlite3 storage/development.sqlite3 \
  "SELECT COUNT(*) FROM messages WHERE input_tokens IS NOT NULL
    OR output_tokens IS NOT NULL OR cache_read_tokens IS NOT NULL
    OR cache_write_tokens IS NOT NULL OR thinking_tokens IS NOT NULL;"      # before

time bin/rails db:migrate
#   -> This is the go/no-go number. Kamal's deploy_timeout defaults to 30s and
#      config/deploy.yml does not override it, so a migration slower than that
#      is reported as a FAILED deploy while still running on production. On
#      SQLite every remove_column/rename_column goes through alter_table, which
#      copies the whole table twice; `messages` is hit 12 times, so runtime
#      scales with roughly 24x its row count, not 1x. Over ~10s here: set
#      deploy_timeout in config/deploy.yml before deploying.

sqlite3 storage/development.sqlite3 "SELECT COUNT(*) FROM ruby_llm_models;"  # after — MUST match
sqlite3 storage/development.sqlite3 "SELECT COUNT(*) FROM ruby_llm_usages;"  # after — MUST match
#   -> The usages count MUST equal the token-column count above.
#      backfill_usage_entries SKIPS any message whose provider/model_id are
#      null and whose chat has no ruby_llm_model_id, and
#      remove_legacy_message_columns then drops the source columns. A shortfall
#      is silent, irreversible data loss and nothing else in this runbook
#      catches it.

# 1.6 Structural checks. Both must be clean.
sqlite3 storage/development.sqlite3 "PRAGMA integrity_check; PRAGMA foreign_key_check;"
sqlite3 storage/development.sqlite3 \
  "SELECT COUNT(*) FROM ruby_llm_tool_calls WHERE message_type IS NULL;"    # MUST be 0

# 1.7 Every offered model still resolves against the rehearsed copy.
bin/verify-model-registry

# 1.8 Give yourself your dev database back — same sidecar rule.
cp storage/development.sqlite3.mine storage/development.sqlite3
rm -f storage/development.sqlite3-wal storage/development.sqlite3-shm
```

**What to expect.** The migration completes in well under a second on a database
this size (0.68s locally against 410 models / 423 messages / 56 tool calls) and
preserves row counts exactly: `models` → `ruby_llm_models` is a rename, not a
rebuild. `ruby_llm_usages` is created and gets one row per message that carried
token data. `ruby_llm_batches` is created empty.

> **Do not confuse this count with a refresh.** The *migration* preserves the
> `ruby_llm_models` row count exactly. A `RubyLLM.models.refresh!` **grows** it —
> v1's refresh wrote only OpenRouter discovery, while v2 fetches the published
> registry for every provider (410 → 1464 locally on first refresh). If the count
> changed, attribute it to whichever step you just ran. See runbook 03.

If either of step 1.5's paired counts differ, or 1.6 reports anything, **stop** — do not
deploy. Production has data shapes the rehearsal just found and the plan did not.

## 2. Before deploying

```bash
# 2.0 Check your shell FIRST. Both `kamal deploy` and `kamal app boot`
#     re-source .kamal/secrets from the caller's environment (`kamal app start`
#     does not — it reuses the container's env). SMTP_PASSWORD and
#     GITHUB_CLIENT_SECRET come from your shell, so a local dev export ships
#     silently to production. This has happened (2026-05-15).
#
#     Prefixes cannot tell a stale key from a live one — every Resend key
#     starts `re_` — so compare hashes against what production runs now.
for v in SMTP_PASSWORD GITHUB_CLIENT_SECRET; do
  mine=$(printenv "$v" | shasum | cut -c1-8)
  live=$(kamal app exec --reuse "sh -c 'printenv $v | shasum | cut -c1-8'" | sed -n '2p')
  echo "$v  shell=$mine  prod=$live"
done
#   -> MUST match. A mismatch means your shell would overwrite production's
#      value. Fix your environment before going further.

# 2.1 Capture the currently-running version. You need this to roll back, and
#     it is unavailable once the new one is running.
#
#     Take line 2, not `tail -1`: kamal prints "App Host: <ip>" first and ends
#     with a blank line, so `tail -1` returns EMPTY. An empty --version is not
#     `.presence`, so Kamal falls through to the LOCAL git SHA — which during a
#     rollback is the v2 image, and booting that against a restored v1 database
#     re-runs the one-way migration over the snapshot you just restored.
PREV=$(kamal app version | sed -n '2p')
[ -n "$PREV" ] || echo "FAILED to capture the running version — do not deploy"
echo "PREV=$PREV"     # write this down as well; $PREV dies with your shell
```

> Any pipe applied to **kamal's own stdout** has to skip the `App Host:` line.
> Pipes *inside* a quoted container command (`kamal app exec --reuse "... | tail -3"`)
> run in the container and are unaffected.

```bash
# 2.2 Check for chats parked mid-tool-round. backfill_tool_results moves
#     messages.tool_call_id onto ruby_llm_tool_calls.result_id and then drops
#     the column, so a turn sitting between tool_use and tool_result is
#     simplest to complete or cancel beforehand.
kamal app exec --primary "bin/inspect-chat <project_id>"
```

Anything reported as `has no following tool result` on an *active* project is
worth finishing or cancelling first. Historical ones are fine — they migrate as
they are.

## 3. Deploy

```bash
# 3.1 Snapshot. The deploy itself migrates, so this is the last moment.
#     (If the rehearsal snapshot from 1.1 is still fresh, this replaces it.)
kamal app exec --reuse \
  "sqlite3 /rails/storage/production.sqlite3 \".backup '/rails/storage/production.sqlite3.pre-v2'\""

# 3.2 Pre-build, so the outage below is boot+migrate rather than
#     build+push+boot+migrate.
kamal build push

# 3.3 STOP the app before anything migrates. `kamal deploy` on its own boots
#     the new container, migrates, and only routes traffic once it is healthy —
#     leaving the OLD v1 container live against tables the migration has just
#     renamed. In that window `GET /projects/:id` raises
#     "no such table: tool_calls" on every project page, and because
#     SOLID_QUEUE_IN_PUMA is true a v1 ChatRespondJob writes dropped columns;
#     if its assistant(tool_use) already persisted, the tool_result never lands
#     and that chat is permanently dead. A planned minute of downtime is
#     cheaper. Do not skip this step to save it.
kamal app stop

# 3.4 Deploy. db:prepare runs the migration during boot, with nothing attached.
kamal deploy

# 3.5 If `kamal deploy` exited NON-ZERO, do NOT assume nothing happened. Kamal
#     stops the NEW container on a failed healthcheck, but the migration has
#     already committed — leaving the pre-upgrade image on a v2 schema, the one
#     state neither image can read. Check before deciding, and go to section 5
#     if it ran.
kamal app exec --reuse "bin/rails db:migrate:status | tail -3"

# 3.6 Confirm the migration ran cleanly rather than assuming it did.
kamal app logs --lines 100

# 3.4 Confirm the schema and the registry on the running container.
kamal app exec --reuse "bin/rails db:migrate:status | tail -3"
kamal app exec --reuse "bin/verify-model-registry"
```

`HIFUMI_AGENT_IMAGE` points at the same image tag (`config/deploy.yml:37`), so
sandboxed codegen containers pick up the new bundle with no separate action.

## 4. Verify

Exercise the four RubyLLM-backed stages in order — they fail independently, and
a passing chat says nothing about the planners.

1. **chat** — send a message; the reply streams.
2. **plan_creation** — ask for an app and confirm; the pill renders and an
   `Instruction` with `Revision` rows appears.
3. **template** — let the build reach the template step; no `InvalidPick`.
4. **plan_modification** — ask for a change on a built project; a plan comes back.

Then, on a real project:

```bash
kamal app exec --primary "bin/inspect-chat <project_id>"   # expect: no structural issues
```

## 5. Recover

There is no `down`. Rollback is **code and data, in that order: stop, restore,
boot.**

```bash
# 5.1 Stop the app so nothing holds the database open.
kamal app stop

# 5.2 Restore over the volume, with the sidecars removed. This runs without a
#     container, which is the point — see the WAL constraint above.
ssh root@77.42.95.154 "docker run --rm -v hifumi_dev_storage:/s alpine sh -c \
  'rm -f /s/production.sqlite3-wal /s/production.sqlite3-shm && \
   cp /s/production.sqlite3.pre-v2 /s/production.sqlite3'"

# 5.3 Bring back the pre-upgrade version (PREV, from step 2.1). db:prepare
#     finds the v1 schema and no pending migration, so it is a no-op.
# 5.3 Bring back the pre-upgrade version (PREV, from step 2.1). An EMPTY
#     --version resolves to the local git SHA, i.e. the v2 image, which would
#     re-run the one-way migration over the database you just restored.
[ -n "$PREV" ] || echo "refusing: PREV is unset — recover it before continuing"
kamal app start --version="$PREV"      # preferred: reuses the existing container
```

Only if that container is gone — note the secrets warning below, which applies
to `boot` but not to `start`:

```bash
kamal app boot --version="$PREV"
```

```bash
# 5.4 Confirm you are on v1 code AND v1 data. Without this the failure mode in
#     5.3 is silent: the site comes back up either way.
kamal app exec --reuse "bin/rails db:migrate:status | tail -3"
#   -> 20260822224622 MUST read "down"
kamal app exec --reuse \
  "sqlite3 /rails/storage/production.sqlite3 'SELECT COUNT(*) FROM models;'"
#   -> MUST succeed. "no such table: models" means you re-migrated.

# 5.5 Discard jobs enqueued under v2. Solid Queue lives in its own database
#     (config/database.yml), so the restore above did not touch it, and those
#     jobs now point at rows the restored primary does not have. They will not
#     discard themselves — `discard_on ActiveJob::DeserializationError` is
#     commented out in app/jobs/application_job.rb — they pile into
#     solid_queue_failed_executions instead.
kamal app exec --reuse \
  "bin/rails runner 'SolidQueue::Job.where(finished_at: nil).delete_all'"
```

> ⚠️ **Do not restore via `kamal app exec --reuse`.** It needs a running
> container — exactly the state that makes the copy unsafe.

> ⚠️ **Bare `kamal app start` leaves production down.** It looks for an
> unversioned container name, fails to match the real versioned one, and stops
> there. Always pass `--version`. (`kamal app restart` does not exist in Kamal
> 2.11.0.)

> ⚠️ **`kamal app boot` re-sources `.kamal/secrets` from your shell.**
> `SMTP_PASSWORD` and `GITHUB_CLIENT_SECRET` are read from the caller's
> environment, so a local export can silently push the wrong value to
> production — this has happened before (2026-05-15). Prefer `app start`, and if
> you must use `boot`, check your shell first:
> `echo "${SMTP_PASSWORD:0:4} ${GITHUB_CLIENT_SECRET:0:4}"`.

### If you only realise later

The snapshot at `/rails/storage/production.sqlite3.pre-v2` stays on the volume
until deleted, so 5.1–5.3 remain available. What it costs is **everything
written since the deploy** — chats, projects, instructions. Past a few minutes of
real traffic, rolling forward with a fix is usually better than rolling back;
weigh that before running 5.2.

## Future

- **Once 2.0 ships to RubyGems**: replace the git pin in `Gemfile` with a version
  constraint, `bundle update ruby_llm`, redeploy. No migration involved — the
  schema work is done.
- **Re-pinning before then**: the pin is a reviewed decision, not a moving
  target. `main` moves daily; re-run the compatibility checks recorded in
  `thoughts/shared/plans/2026-08-19/ruby-llm-v2-upgrade.md` ("Working Against
  the Pinned SHA") against any candidate SHA before bumping it.
- **`ruby_llm_usages` grows one row per provider attempt.** Nothing reads it
  yet. Worth revisiting if it becomes the largest table.
