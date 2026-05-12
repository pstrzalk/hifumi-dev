---
date: 2026-05-11T14:00:54+0000
researcher: Paweł Strzałkowski
git_commit: 79deb8438b05401f4c914625d6c411796e0de16e
branch: main
repository: rails-app-generator
topic: "Per-user, per-stage LLM model configuration via OpenRouter"
tags: [research, codebase, openrouter, ruby_llm, roast, profile, account-ui]
status: complete
last_updated: 2026-05-11
last_updated_by: Paweł Strzałkowski
---

# Research: Per-user, per-stage LLM model configuration via OpenRouter

**Date**: 2026-05-11T14:00:54+0000
**Researcher**: Paweł Strzałkowski
**Git Commit**: 79deb8438b05401f4c914625d6c411796e0de16e
**Branch**: main
**Repository**: rails-app-generator

## Research Question

> We have a set of LLMs used from OpenRouter. I want to add configuration to user profile, where they can select any model for any stage. This configuration would go at user level (alt would be Project level, but I don't think we need it). The current selection would be the default. Check if it's possible with OpenRouter. It would be good to show the cost for each model when they select it as well.

## Summary

The app calls an LLM at **six distinct stages**, all currently routed through OpenRouter in production. Four stages call RubyLLM directly (chat reply, plan creation, plan modification, frontend template picker); two stages go through the `claude` CLI subprocess via Roast (code generation/remediation, docs update). Every call site already threads the per-user `Profile#openrouter_api_key` (encrypted) — so the plumbing for per-user configuration exists; what is missing is per-user *model* selection.

OpenRouter exposes a `GET /api/v1/models` endpoint that returns full pricing (per-token strings) and capabilities for every model, so a model-picker UI with cost display is feasible. Two important nuances for cost rendering and stage-vs-stage compatibility are documented below.

The natural extension is to add per-stage model columns to the `profiles` table and surface them in `devise/registrations/edit.html.erb`. The codebase already has an empty `models` table (`acts_as_model` registered, never populated) that could cache the OpenRouter model list locally.

## Detailed Findings

### The six LLM stages

| # | Stage | File:Line | Transport | Current model | Selection mechanism |
|---|---|---|---|---|---|
| 1 | Chat reply | [`app/agents/generator_agent.rb:2`](app/agents/generator_agent.rb#L2) (declaration); [`app/jobs/chat_respond_job.rb:16`](app/jobs/chat_respond_job.rb#L16) (invocation) | RubyLLM streaming | `anthropic/claude-haiku-4.5` | Hardcoded `model "..."` on `GeneratorAgent` class |
| 2 | Plan creation (new app) | [`app/services/plan_application_creation/ad_hoc_llm.rb:4,16`](app/services/plan_application_creation/ad_hoc_llm.rb#L4) | RubyLLM `with_schema` (structured output) | `anthropic/claude-haiku-4.5` | Module constant `MODEL` |
| 3 | Plan modification (existing app) | [`app/services/plan_application_modification/ad_hoc_llm.rb:4,16`](app/services/plan_application_modification/ad_hoc_llm.rb#L4) | RubyLLM `with_schema` | `anthropic/claude-haiku-4.5` | Module constant `MODEL` |
| 4 | Frontend template picker | [`lib/templates/picker.rb:27,39`](lib/templates/picker.rb#L27) | RubyLLM `with_schema` | `anthropic/claude-haiku-4.5` | Module constant `MODEL` |
| 5 | Code generation + remediation (Roast W2.3 / W2.R) | [`lib/roast/revision_workflow.rb:36-41, 75-77, 204`](lib/roast/revision_workflow.rb#L36) | Roast → `claude` CLI subprocess | alias `"sonnet"` → `anthropic/claude-sonnet-4.6` | ENV `RAILS_APP_GENERATOR_MODEL` via `Roast::WorkflowEnv.claude_model` |
| 6 | Docs update (Roast W2.6) | [`lib/roast/revision_workflow.rb:55-58, 288`](lib/roast/revision_workflow.rb#L55) | Roast → `claude` CLI subprocess (tools restricted to `Edit,Read`) | alias `"haiku"` → `anthropic/claude-haiku-4.5` | ENV `RAILS_APP_GENERATOR_DOCS_MODEL` via `Roast::WorkflowEnv.docs_model` |

### How the per-user OpenRouter key is threaded today

Profile encryption: [`app/models/profile.rb:4`](app/models/profile.rb#L4) — `encrypts :openrouter_api_key` (Rails 8 Active Record Encryption; ciphertext stored in the `openrouter_api_key` string column).

| Stage | Key read at | Applied via |
|---|---|---|
| 1 (chat) | [`chat_respond_job.rb:8`](app/jobs/chat_respond_job.rb#L8) | `RubyLLM.context { c.openrouter_api_key = api_key }` → `.with_context(ctx)` |
| 2 (plan creation) | [`create_application.rb:32`](app/tools/create_application.rb#L32) → forwarded to `ad_hoc_llm.rb:15` | `RubyLLM.context` |
| 3 (plan modification) | [`modify_application.rb:32`](app/tools/modify_application.rb#L32) → forwarded to `ad_hoc_llm.rb:15` | `RubyLLM.context` |
| 4 (picker) | [`execute_instruction_job.rb:127`](app/jobs/execute_instruction_job.rb#L127) → `picker.rb:38` | `RubyLLM.context` |
| 5, 6 (Roast) | [`execute_instruction_job.rb:164,176`](app/jobs/execute_instruction_job.rb#L164) | subprocess env `OPENROUTER_API_KEY=...`; [`bin/roast-openrouter:10`](bin/roast-openrouter#L10) re-exports as `ANTHROPIC_AUTH_TOKEN` |

A placeholder global key sits in [`config/initializers/ruby_llm.rb:13-14`](config/initializers/ruby_llm.rb#L13) — present only to satisfy RubyLLM's eager `ensure_configured!` check (see memory `project_ruby_llm_eager_provider_check.md`). The real key is always the per-user one threaded via `with_context` (or via subprocess env for Roast).

### Roast: how stages 5 and 6 pick their model

`lib/roast/revision_workflow.rb` declares three named agent blocks in its `config` (lines 36-77):

- **Default (unnamed) agent** — `provider :claude`, `model CLAUDE_MODEL`. Used implicitly by `agent(:generate_code)` at line 204.
- **`agent(:fix)`** — inherits default model, only overrides `command` to add `--max-budget-usd`.
- **`agent(:update_docs)`** — `model DOCS_MODEL`, `command ["claude", "--tools", "Edit,Read"]`.

`CLAUDE_MODEL` and `DOCS_MODEL` are bound at workflow load from ENV via the gateway module [`lib/roast/workflow_env.rb:23-33`](lib/roast/workflow_env.rb#L23):

```ruby
def claude_model(env = ENV) = env.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet")
def docs_model(env = ENV)   = env.fetch("RAILS_APP_GENERATOR_DOCS_MODEL", "haiku")
```

[`ExecuteInstructionJob#execute_revision`](app/jobs/execute_instruction_job.rb#L160) builds the subprocess env at lines 173-178:

```ruby
env = {
  "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
  "RAILS_APP_GENERATOR_MODEL"     => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet"),
  "OPENROUTER_API_KEY"            => api_key,
  "RAILS_ENV"                     => "development"
}
```

`RAILS_APP_GENERATOR_DOCS_MODEL` is **not** in this hash today, so `agent(:update_docs)` always resolves to `"haiku"` in practice regardless of any ENV in the job's own process. To make the docs stage user-configurable, the job would need to add this key explicitly.

The `bin/roast-openrouter` wrapper resolves Claude CLI-style short aliases to full OpenRouter IDs ([`bin/roast-openrouter:12-14`](bin/roast-openrouter#L12)):

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL="anthropic/claude-opus-4.6"
export ANTHROPIC_DEFAULT_SONNET_MODEL="anthropic/claude-sonnet-4.6"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="anthropic/claude-haiku-4.5"
```

This means the Roast subprocess accepts `"sonnet"` / `"haiku"` / `"opus"` aliases that get mapped to the full IDs above. Passing a non-alias (e.g. `"anthropic/claude-opus-4.6"` directly as `RAILS_APP_GENERATOR_MODEL`) has not been tested in this codebase — the alias-resolution path is what's currently exercised. For non-Anthropic models (Gemini, OpenAI, etc.), the `ANTHROPIC_DEFAULT_*` mapping would not apply, and the `claude` CLI subprocess is built around the Anthropic message API surface, so non-Anthropic models are likely unsupported for stages 5 and 6 without further work. The four RubyLLM stages (1-4) are provider-agnostic via OpenRouter and would accept any OpenRouter model ID.

### Profile/User data model and account UI

**`profiles` schema** ([`db/schema.rb:121-129`](db/schema.rb#L121)):

| Column | Type | Notes |
|---|---|---|
| `user_id` | integer | NOT NULL, UNIQUE FK |
| `first_name` | string | required at model level |
| `last_name` | string | required at model level |
| `openrouter_api_key` | string | encrypted via `encrypts`; required at model level |
| `created_at`, `updated_at` | datetime | NOT NULL |

**Model code**:
- [`app/models/user.rb`](app/models/user.rb) — Devise (`:database_authenticatable, :registerable, :recoverable, :rememberable, :validatable, :omniauthable [github]`); `has_one :profile, dependent: :destroy, inverse_of: :user, autosave: true`; `accepts_nested_attributes_for :profile`; `validates :profile, presence: true`.
- [`app/models/profile.rb`](app/models/profile.rb) — `belongs_to :user, inverse_of: :profile`; `encrypts :openrouter_api_key`; `validates :first_name, :last_name, :openrouter_api_key, presence: true`.

**Registrations controller** ([`app/controllers/users/registrations_controller.rb`](app/controllers/users/registrations_controller.rb)):
- `new` (lines 5-9) builds `resource.build_profile` so `fields_for :profile` renders inputs.
- `update` (lines 11-17) strips a blank `openrouter_api_key` from submitted params before delegating, so the encrypted key is preserved when the user leaves that field blank.
- `update_resource` (lines 24-33) routes through `update_with_password` only when password or email is changing.
- Strong-params methods are private:
  - `configure_sign_up_params` permits `profile_attributes: [:first_name, :last_name, :openrouter_api_key]`.
  - `configure_account_update_params` permits `profile_attributes: [:id, :first_name, :last_name, :openrouter_api_key]`.

These two methods are the single place to add any new profile column to the permitted-params list.

**Views**:
- [`app/views/devise/registrations/new.html.erb`](app/views/devise/registrations/new.html.erb) — sign-up form. Profile fields collected (in nested `fields_for :profile`, lines 28-49): First name, Last name, OpenRouter API key. The API-key field is the last in the block (lines 39-48), preceded by a helper paragraph linking to openrouter.ai/keys.
- [`app/views/devise/registrations/edit.html.erb`](app/views/devise/registrations/edit.html.erb) — account edit page. Three sections: profile/account form (lines 1-69), GitHub connection (lines 71-93), danger zone (lines 96-108). Profile-edit fields in `fields_for :profile` (lines 15-36) match the sign-up set; API-key field shows placeholder `"(unchanged — leave blank to keep current key)"`.
- The blank-key-preservation logic in the controller is what makes that placeholder behave correctly.

**Hifumi classes used in these forms** (canonical neighbors for any new UI):
- `eyebrow` — mono caps, `var(--fg-muted)`, 18px (section pre-headers).
- `h-section` — sans-serif 40px 600 weight (page H1).
- `field-label`, `field-input` — every input pair on the page.
- `btn btn--accent`, `btn btn--outline`, `btn btn--danger` — buttons.
- `section-rule` — divider between subsections.

Tokens live in [`app/assets/tailwind/application.css`](app/assets/tailwind/application.css); see `docs/02-architecture/04-design-system.md` for the full inventory.

**Routes** ([`config/routes.rb:2-6`](config/routes.rb#L2)):

```ruby
devise_for :users,
  controllers: {
    registrations: "users/registrations",
    omniauth_callbacks: "users/omniauth_callbacks"
  }
```

User-facing URLs: `/users/sign_up` (sign-up), `/users/edit` (account edit), `/users` PUT (update), `/users` DELETE (cancel account). No separate `account` namespace.

**Tests touching Profile**:
- [`test/fixtures/profiles.yml`](test/fixtures/profiles.yml) — `owner` and `other` fixtures with `first_name`/`last_name` only; `openrouter_api_key` is intentionally NULL (encryption can't be applied via raw fixture INSERT).
- [`test/models/profile_test.rb`](test/models/profile_test.rb) — one test: API key encrypts at rest, decrypts on read.
- [`test/models/user_test.rb`](test/models/user_test.rb) — three tests covering profile presence + nested-attributes path.
- [`test/controllers/users/registrations_controller_test.rb`](test/controllers/users/registrations_controller_test.rb) — eight tests: sign-up form renders all profile fields, happy/sad paths, blank-key preservation on update, password-change branches.

**Migration history** ([`db/migrate/`](db/migrate)): The `profiles` table was created on 2026-04-29 in `20260429092209_create_profiles.rb` and has not been altered since. The established follow-up pattern is `add_<column>_to_profiles` (mirroring `add_step4_columns_to_instructions_and_revisions`, `add_preview_state_to_projects`).

### OpenRouter API: models and pricing

Endpoint: `GET https://openrouter.ai/api/v1/models` (auth required, bearer token).

Response shape: `{ data: Array<Model> }`. Per-model fields most relevant for a picker UI:

- `id` (e.g. `"anthropic/claude-sonnet-4.6"`), `canonical_slug`, `name`, `description`
- `created` (unix timestamp), `knowledge_cutoff` (ISO 8601)
- `context_length` (int), `architecture` (input/output modalities, tokenizer)
- `pricing` object — **all values are strings in USD per token**, e.g. `"prompt": "0.000008"`, `"completion": "0.000024"`; also `image`, `image_output`, `request`, `input_cache_read`, `input_cache_write`, `internal_reasoning`, `web_search`, `discount`
- `supported_parameters` — array of strings like `"tools"`, `"structured_outputs"`, `"vision"`, `"response_format"`
- `top_provider` (context, max completion, is_moderated), `per_request_limits`

**Pricing display gotcha**: values are per-token strings, not per-million. Convert with `(pricing["prompt"].to_f * 1_000_000).round(4)` to display "$X/M input tokens" — the format OpenRouter's own UI uses on model detail pages.

**Filtering query params**: `supported_parameters` (comma-separated capabilities), `output_modalities`, `category`, `use_rss`. For our stages: `?supported_parameters=tools` narrows to tool-use capable models (relevant for stage 1, which registers a mutation tool). Stages 2/3/4 require `structured_outputs`. Stage 6 (`update_docs`) needs no special capability (it uses the `claude` CLI's own Edit/Read tools, not OpenRouter tool-use).

**Per-provider breakdown**: `GET /api/v1/models/{author}/{slug}/endpoints` returns per-provider pricing, latency, throughput, uptime. Useful if we want to surface latency or "moderated vs un-moderated" details on the picker.

**Caching guidance** (from sub-agent research): no documented ETag/Last-Modified; OpenRouter says the schema is "cached at the edge." Reasonable client-side TTL: 1 hour, refreshed via a background job. RSS variant (`?use_rss=true`) is available for change detection. Hitting the metadata endpoint does not appear to consume credits (not explicitly documented, but rate-limit docs only describe inference).

**Aliases**: OpenRouter does **not** accept bare `"sonnet"` / `"haiku"` / `"opus"`. It accepts:
- Full IDs: `anthropic/claude-sonnet-4.6`
- Tilde-prefixed "latest" aliases: `~anthropic/claude-sonnet-latest`
- Dated slugs: `anthropic/claude-3-5-haiku-20241022`

This is relevant for stages 5/6: the `bin/roast-openrouter` alias-resolution exists precisely because the Claude CLI accepts the short names locally; OpenRouter itself does not.

### The dormant `Model` registry table

[`app/models/model.rb`](app/models/model.rb) declares `acts_as_model` (RubyLLM's model registry). The `models` table ([`db/schema.rb:101-119`](db/schema.rb#L101)) has columns matching the OpenRouter response shape almost 1:1: `model_id`, `provider`, `family`, `name`, `model_created_at`, `context_window`, `max_output_tokens`, `knowledge_cutoff`, `modalities` (json), `capabilities` (json), `pricing` (json), `metadata` (json).

Unique index on `[provider, model_id]`. `chats` and `messages` both have `model_id` FKs into this table ([`db/schema.rb:195, 201`](db/schema.rb#L195)).

No code currently populates or reads this table. Per prior research (`thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md`), `bin/rails ruby_llm:load_models` was never run. The table is structurally ready to cache the OpenRouter model list for a picker UI.

## Code References

### LLM call sites
- `app/agents/generator_agent.rb:2` — Stage 1: `model "anthropic/claude-haiku-4.5"` class declaration
- `app/jobs/chat_respond_job.rb:11-16` — Stage 1: `RubyLLM.context` build + `.with_context(ctx).complete`
- `app/services/plan_application_creation/ad_hoc_llm.rb:4,15-18` — Stage 2: `MODEL` constant, `ctx.chat(model: MODEL).with_schema(PlanSchema).ask(user)`
- `app/services/plan_application_modification/ad_hoc_llm.rb:4,15-18` — Stage 3: same pattern as Stage 2
- `lib/templates/picker.rb:27,37-44` — Stage 4: picker with inline JSON `SCHEMA` (not a `RubyLLM::Schema` subclass)
- `lib/roast/revision_workflow.rb:25-28` — Roast workflow constants bound from `WorkflowEnv`
- `lib/roast/revision_workflow.rb:36-77` — Three named agent configs (default, `:fix`, `:update_docs`)
- `lib/roast/revision_workflow.rb:204` — Stage 5: `agent(:generate_code)` inherits default model
- `lib/roast/revision_workflow.rb:75-77,83-132` — Stage 5b: `agent(:fix)` remediation, two-iteration cap
- `lib/roast/revision_workflow.rb:55-58,288` — Stage 6: `agent(:update_docs)` with `model DOCS_MODEL`
- `lib/roast/workflow_env.rb:23-33` — `claude_model` / `docs_model` ENV gateways with defaults
- `app/jobs/execute_instruction_job.rb:173-178` — Subprocess env hash (only `RAILS_APP_GENERATOR_MODEL` forwarded; not docs)
- `app/jobs/execute_instruction_job.rb:244-250` — Runner selection: `bin/roast-openrouter` (prod / `FORCE_OPENROUTER=1`) vs `bin/roast-claudesubscription` (dev)
- `bin/roast-openrouter:12-14` — Anthropic alias → OpenRouter ID mapping

### Profile / account UI
- `app/models/user.rb:6-9` — has_one :profile, accepts_nested_attributes_for, presence validation
- `app/models/profile.rb:4-6` — `encrypts :openrouter_api_key`, required-fields validation
- `app/controllers/users/registrations_controller.rb:42-50` — `configure_sign_up_params` / `configure_account_update_params` — the strong-params allow-list to extend
- `app/controllers/users/registrations_controller.rb:11-17` — blank-key strip on update (the model for new "leave blank to keep current" fields, if any)
- `app/views/devise/registrations/edit.html.erb:15-36` — `fields_for :profile` block, insertion point for new selects after line 35
- `app/views/devise/registrations/new.html.erb:28-49` — `fields_for :profile` block, insertion point for new selects after line 48
- `db/schema.rb:121-129` — `profiles` table columns
- `db/schema.rb:101-119` — `models` table columns (dormant registry)

### Tests setting the pattern for new Profile columns
- `test/models/profile_test.rb` — model-level tests (one per logical branch)
- `test/controllers/users/registrations_controller_test.rb` — eight tests covering the controller's logical branches (sign-up render, happy, validation failure, password change branches, key preservation)
- `test/fixtures/profiles.yml` — fixtures (encrypted columns left NULL)

### Initializer + key-threading caveats
- `config/initializers/ruby_llm.rb:11-15` — placeholder global key explanation
- See memory: `project_ruby_llm_eager_provider_check.md`, `project_three_llm_call_sites.md` (note: now four RubyLLM sites — the picker is the additional one beyond ChatRespondJob, CreatePlan::AdHocLLM)

## Architecture Documentation

**Per-user secret threading pattern** (established convention): every LLM call site reads `project.user.profile.openrouter_api_key` (or `instruction.project.user.profile.openrouter_api_key`), raises `"Project owner has no OpenRouter API key"` if blank, and applies the key either via `RubyLLM.context { |c| c.openrouter_api_key = api_key }` + `with_context(ctx)` (RubyLLM sites) or via subprocess env (`OPENROUTER_API_KEY=...` for Roast). Any new per-user config column should be threaded the same way.

**Model selection is hardcoded today**, with two locations:
- RubyLLM stages — each call site has its own `MODEL` constant or class-level `model "..."` declaration. There is no shared registry.
- Roast stages — bound from ENV via `Roast::WorkflowEnv`; the job process forwards `RAILS_APP_GENERATOR_MODEL` but not `RAILS_APP_GENERATOR_DOCS_MODEL`.

**Dormant model registry**: the `models` table is shaped to mirror OpenRouter's `pricing` and `capabilities` JSON columns. Loading it (via a refresh job hitting `GET /api/v1/models`) would give the picker UI a single source of truth for the dropdown options without per-request roundtrips to OpenRouter.

**Hifumi UI**: any new form fields go through `field-label` + `field-input` (or `select` styled similarly). Mono caps for labels, sentence case for option text; no emoji.

## Historical Context (from thoughts/)

- Memory `project_three_llm_call_sites.md` (now stale at the count — the picker is a fourth RubyLLM site): documents the recurring requirement to thread the per-user OpenRouter key at every new LLM call site.
- Memory `project_ruby_llm_eager_provider_check.md`: explains why the global placeholder key in `config/initializers/ruby_llm.rb` exists — RubyLLM's `Provider#initialize` fires `ensure_configured!` eagerly, before `with_context` can take effect.
- Memory `project_phase_5_candidates_after_4d.md`: previously listed a "drop placeholder openrouter key" candidate; per-stage model selection would interact with that if a profile-level key gets validated before construction.
- `thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` (per sub-agent): confirms the `models` table is empty and `bin/rails ruby_llm:load_models` was never run.

## Open Questions

1. **Does the Roast `claude` CLI subprocess work with non-Anthropic OpenRouter models?** The `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` mechanism in `bin/roast-openrouter` is built around OpenRouter's Anthropic-compatible API skin. Pointing it at e.g. `openai/gpt-4o` has not been tested. If non-Anthropic models are out of scope for stages 5/6, the per-stage picker should be filtered accordingly (or stages 5/6 should expose a more restricted list).
2. **Per-stage matrix vs single override**: the request says "any model for any stage," which implies six independent dropdowns. An alternative is to group: one model for "planning/chat" (stages 1-4 share `claude-haiku-4.5` today) and one for "code generation" (stage 5) and one for "docs" (stage 6). The current default split is essentially 3 buckets: chat/plan (haiku), code (sonnet), docs (haiku). Worth confirming whether the user wants six selects or three.
3. **Cost rendering scope**: do we show only `prompt` + `completion` per-million-tokens, or also `input_cache_read`/`input_cache_write` (relevant once prompt caching is enabled) and `image` (relevant for vision use)?
4. **Model registry refresh strategy**: populate the dormant `models` table via a periodic Solid Queue recurring job, or fetch on-demand with a 1-hour cache? The former matches how `models` is shaped; the latter is simpler to ship.
5. **`RAILS_APP_GENERATOR_DOCS_MODEL` plumbing gap**: today the job hardcodes `"haiku"` for stage 6 because it does not forward this ENV. Adding a per-user docs-model column requires also adding the env key to the subprocess hash at `app/jobs/execute_instruction_job.rb:173-178`.
6. **Capability gating per stage**: stages 2/3/4 use `with_schema`; OpenRouter models that don't support `structured_outputs` would 400. Stage 1 uses tool-use. The picker UI should probably narrow each stage's dropdown by `supported_parameters` to prevent the user from picking an incompatible model.

## Related Research

- `thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md` — audit that first documented the dormant `models` table and the `acts_as_model` declaration.
- `docs/02-architecture/02-layer-integration.md` — canonical description of how RubyLLM, Roast, and Solid Queue integrate; useful background for understanding why the stages are split the way they are.
- `docs/02-architecture/03-tech-stack.md` — gem inventory.
