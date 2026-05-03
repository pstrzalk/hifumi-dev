---
date: 2026-05-02T10:08:43+0200
researcher: Paweł Strzałkowski
git_commit: 5114998bd89898b31df7908ee98945e0fc9791cc
branch: main
repository: rails-app-generator
topic: "Adding 5 randomized design systems (Cyber, Flower, Earth, Office, Kids) to generated apps"
tags: [research, codebase, design-system, tailwind, skeleton, roast, prompts]
status: complete
last_updated: 2026-05-02
last_updated_by: Paweł Strzałkowski
---

# Research: Adding 5 randomized design systems to generated apps

**Date**: 2026-05-02T10:08:43+0200
**Researcher**: Paweł Strzałkowski
**Git Commit**: 5114998bd89898b31df7908ee98945e0fc9791cc
**Branch**: main
**Repository**: rails-app-generator

## Research Question

Generated apps use Tailwind, but unless styling is asked for in the user's prompt, the generator currently produces plain default-Tailwind + Rails forms. The goal: prepare 5 predefined design systems — **Cyber**, **Flower** (pastel, colorful), **Earth** (pastel, mellow), **Office** (JIRA-like), **Kids** (bright) — covering colors, fonts, sizes, gaps, etc., randomly chosen per project and applied to the generated app. This document maps the existing system so we can plug in those design systems.

## Summary

Generated apps are produced by copying `lib/preview/skeleton/` (a stock `rails new --css tailwind` Rails 8.1.3 app) plus `lib/preview/skeleton-overlay/` into a per-project workspace, then having an LLM (Claude CLI invoked from a Roast workflow) write code into that workspace. Today the styling story is two lines:

1. The skeleton's `app/assets/tailwind/application.css` is `@import "tailwindcss";` — nothing else.
2. The W2 revision workflow's Rules block includes the single line `Tailwind CSS for styling` ([`lib/roast/revision_workflow.rb:185`](lib/roast/revision_workflow.rb#L185)).

The LLM has no design tokens, no preferred component classes, no view-file context to read from. There is no per-project styling variance — every workspace starts identical.

To plug in 5 randomized design systems, three integration points need to change:

- **Project model**: a `design_system` column (string enum) randomly assigned at creation. No random-attribute pattern exists today on `Project`.
- **Workspace baseline**: the chosen system's CSS (token block + component classes, mirroring Hifumi's structure) needs to land in the workspace's `app/assets/tailwind/application.css` and any font-loading needs to land in `app/views/layouts/application.html.erb`. Either a per-system overlay directory copied during `init_rails_app`, or a templated write driven by `project.design_system`, fits naturally.
- **LLM prompts**: the W2 Rules block needs to surface the available tokens / component classes so the LLM uses them instead of raw Tailwind utility values. Optionally CreatePlan's system prompt can mention them too. The LLM doesn't currently see view files in its workspace snapshot, so token guidance has to come through the prompt, not by example.

The generator's own Hifumi system is the cleanest reference pattern: a single CSS file with a `:root` token block (~60 vars) + component classes (~55), all 100% token-driven so re-theming = swapping `:root` + font imports.

## Detailed Findings

### 1. Generated-app skeleton: what's there today

Every generated app starts as a copy of [`lib/preview/skeleton/`](lib/preview/skeleton/), which is a vanilla `rails new --css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci` (regenerated via [`bin/preview-regen-skeleton`](bin/preview-regen-skeleton)).

**Tailwind setup** (Tailwind v4 via `tailwindcss-rails` gem, no JS toolchain):
- Source: [`lib/preview/skeleton/app/assets/tailwind/application.css`](lib/preview/skeleton/app/assets/tailwind/application.css) — currently one line: `@import "tailwindcss";`
- Built output: [`lib/preview/skeleton/app/assets/builds/tailwind.css`](lib/preview/skeleton/app/assets/builds/tailwind.css) (pre-built, ~2587 chars)
- Manifest: [`lib/preview/skeleton/app/assets/stylesheets/application.css`](lib/preview/skeleton/app/assets/stylesheets/application.css) — empty (Propshaft comments only)
- Build: `bin/rails tailwindcss:build` (one-shot) / `tailwindcss:watch` (dev). [`Procfile.dev:2`](lib/preview/skeleton/Procfile.dev#L2) runs the watcher.
- Gem: [`lib/preview/skeleton/Gemfile:18`](lib/preview/skeleton/Gemfile#L18) — `tailwindcss-rails`
- Asset pipeline: Propshaft only ([`Gemfile:6`](lib/preview/skeleton/Gemfile#L6)), no Sprockets, no `package.json`, no `tailwind.config.js`. Tailwind v4 uses `@import` + auto content-detection.

**Default layout** ([`lib/preview/skeleton/app/views/layouts/application.html.erb:27`](lib/preview/skeleton/app/views/layouts/application.html.erb#L27)):
```erb
<main class="container mx-auto mt-28 px-5 flex">
  <%= yield %>
</main>
```
No nav, no header, no flash partial, no font imports, no brand chrome. `<title>` defaults to `"Rails Application"` ([line 4](lib/preview/skeleton/app/views/layouts/application.html.erb#L4)).

**Skeleton-overlay** ([`lib/preview/skeleton-overlay/`](lib/preview/skeleton-overlay/)) — applied on top of the skeleton at workspace init. Currently only:
- [`config/initializers/preview_iframe.rb`](lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb) — strips `X-Frame-Options`, appends `ENV["PREVIEW_HOST"]` to allowed hosts
- [`bin/preview-entrypoint`](lib/preview/skeleton-overlay/bin/preview-entrypoint) — Docker container ENTRYPOINT (`db:prepare` + `rails server`)

This is the natural shape for additional per-project overlays.

### 2. Workspace initialization flow

[`app/jobs/execute_instruction_job.rb:35-79`](app/jobs/execute_instruction_job.rb#L35-L79) — `init_rails_app(workspace)`:

```ruby
FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton')}/.",         workspace)  # line 37
FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton-overlay')}/.", workspace)  # line 38
# ... log dirs (47-51), master.key (58-60), bundle install (62-67),
# git init + "chore: skeleton baseline" commit (69-76), permissions (79)
```

Workspace setup is **lazy** — it happens on the first `Instruction.execute`, not at project creation. That gives ample room to insert a "write design-system CSS" step between lines 38 and the bundle/commit.

**Per-project ENV pattern (existing)**: [`lib/preview/preview_manager.rb:249`](lib/preview/preview_manager.rb#L249) passes `PREVIEW_HOST=<id>.preview.<domain>` to the running container, read by the overlay initializer above. This is the only existing per-project parameterization channel.

### 3. Project model and creation

**Columns** ([`db/schema.rb:116-126`](db/schema.rb#L116-L126)): `id`, `name` (truncated description), `user_id`, `preview_state`, `preview_container_id`, `preview_error`, `preview_started_at`, timestamps. No design-related fields. No random-attribute callbacks anywhere on `Project`.

**Creation** ([`app/controllers/projects_controller.rb:22-25`](app/controllers/projects_controller.rb#L22-L25)):
```ruby
project = current_user.projects.create!(name: description.truncate(60))
GeneratorAgent.create!(project: project)
first_message = project.chat.user_messages.create!(content: description)
ChatRespondJob.perform_later(first_message.id)
```

Adding a `design_system` column + `before_create :assign_design_system` (`%w[cyber flower earth office kids].sample`) is a clean fit and matches Rails conventions.

### 4. LLM prompt chain — where styling guidance lives

The LLM operates in two layers:

**Conversation layer** (RubyLLM chat with tools):
- [`app/agents/generator_agent.rb:4`](app/agents/generator_agent.rb#L4) — `instructions { prompt("instructions", current_state: chat.project.current_state_prompt) }`
- The `current_state` is a generation-status string from [`app/models/project.rb:45-54`](app/models/project.rb#L45-L54). No styling content. No project name, no project attributes other than generation state.

**Planning layer** (`CreatePlan`):
- [`app/prompts/create_plan_system.md:6`](app/prompts/create_plan_system.md#L6): `"Assume the workspace is an already-initialized Rails 8 app with Tailwind + Hotwire + Devise gems available."`
- Mentions Tailwind exists. Does not say how to use it. No design tokens.

**Execution layer** (Roast workflow, the only place where styling guidance lands):
- [`lib/roast/revision_workflow.rb:182-192`](lib/roast/revision_workflow.rb#L182-L192) — Rules block appended to every revision prompt:
  ```ruby
  parts << <<~RULES
    ## Rules
    - Rails Way: conventions, generators, built-in solutions
    - Tailwind CSS for styling
    - Hotwire (Turbo + Stimulus), no React/Vue
    - Minitest, not RSpec
    - Write tests for new functionality
    - Don't create empty directories or files that aren't needed
    - You are working in #{WORKSPACE} — all paths are relative to this directory
    - The snapshot above is current. Don't glob or list directories to discover what already exists; only read a specific file when you actually need its contents to make the change.
  RULES
  ```
  **Line 185 (`"Tailwind CSS for styling"`) is the only design directive in the entire prompt chain.**

**Workspace snapshot fed to the LLM** ([`lib/roast/revision_workflow.rb:153-166`](lib/roast/revision_workflow.rb#L153-L166)) lists `app/controllers/` and `app/models/` files plus full content of `config/routes.rb` and `application_controller.rb`. **Views are NOT pre-fed** — the LLM has to read them on demand.

**Project metadata reaching the revision prompt**: none. `roast` is invoked as a subprocess from [`app/jobs/execute_instruction_job.rb:131-186`](app/jobs/execute_instruction_job.rb#L131-L186) with kwargs `revision_id`, `revision_summary`, `revision_prompt` only. To thread `project.design_system` to W2.2 you'd extend that subprocess invocation with a new kwarg and read it inside `revision_workflow.rb`.

### 5. Hifumi as the reference pattern (the generator's own UI)

The generator's UI is fully themed via a single file: [`app/assets/tailwind/application.css`](app/assets/tailwind/application.css) (~736 lines). This is the structural template each new design system can mirror.

**File layout** (lines 1-736):
- Line 1: `@import "tailwindcss";`
- Lines 9-105: `:root` token block — ~60 CSS variables
- Lines 110-736: ~55 component classes organized into 11 sections (BASELINE, SEMANTIC TYPE, APP CHROME, FLASH, BUTTONS, FORMS, STATUS TAGS, PROJECT CARD, REVISION LIST, CHAT, COMPOSER, PREVIEW, MARKETING)

**Token taxonomy (carry over to all 5 systems)**:
| Category | Vars | Purpose |
|---|---|---|
| Raw palette | `--rails-50..800`, `--ink-50..900`, `--paper-0..300`, `--steel-50..900`, status (`--ok-*`, `--info-*`, `--warn-*`, `--err-*`) | ~35 tokens, palette source |
| Semantic aliases | `--bg`, `--bg-elevated`, `--bg-sunken`, `--bg-inverse`, `--bg-code`, `--fg`, `--fg-muted`, `--fg-faint`, `--fg-inverse`, `--fg-on-accent`, `--accent`, `--accent-hover`, `--accent-soft`, `--accent-line`, `--border`, `--border-strong`, `--border-faint`, `--rule` | ~17 tokens, the API consumed by component classes |
| Type | `--hi-font-sans`, `--hi-font-mono`, `--hi-font-serif`, `--tracking-tight`, `--tracking-wide`, `--tracking-mono`, `--tracking-caps` | 7 tokens |
| Radius | `--radius-sm/md/lg/pill` | 4 tokens |
| Effects | `--shadow-xs`, `--shadow-sm`, `--focus-ring` | 3 tokens |
| Animation | `--ease-standard`, `--dur-fast`, `--dur-base` | 3 tokens |

**Fonts** load via Google CDN at [`app/views/layouts/application.html.erb:18-21`](app/views/layouts/application.html.erb#L18-L21):
```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans:wght@400;500;600;700&family=Source+Serif+4:opsz,wght@8..60,400;8..60,500;8..60,600&display=swap">
```

**Re-theming pattern** (per [`docs/02-architecture/04-design-system.md`](docs/02-architecture/04-design-system.md)): swap the `:root` block + the font `<link>`. Component classes reference only `var(--*)` tokens, so they re-skin automatically. This is exactly the pattern that maps to "5 design systems share the same component-class API; only `:root` + fonts differ".

### 6. The semantic gap: Hifumi's component classes vs. generated-app needs

Hifumi's classes (`.project-card`, `.revision-row`, `.notice-strip`, `.preview-pane`, etc.) are specific to the *generator's own UI*. A generated to-do-list app needs different component classes — buttons, inputs, navs, cards, lists, tables, badges. The 5 systems would each need a generic-app component-class layer (not Hifumi's generator-specific one) that the LLM can consume:

- Buttons: `.btn`, `.btn--primary`, `.btn--secondary`, `.btn--danger`, `.btn--ghost`, `.btn--sm`
- Forms: `.field`, `.field-label`, `.field-input`, `.field-textarea`, `.field-select`, `.field-error`
- Layout: `.app-shell`, `.app-nav`, `.app-nav-link`, `.container`, `.section`
- Surfaces: `.card`, `.panel`, `.divider`
- Data: `.table`, `.list`, `.list-item`, `.badge`, `.empty-state`
- Feedback: `.alert`, `.alert--ok/info/warn/err`

The LLM would need to be told these classes exist (W2 Rules block) and prefer them over raw utilities. Without that, the LLM defaults to ad-hoc Tailwind utility soup driven by its training data.

## Code References

- `lib/preview/skeleton/app/assets/tailwind/application.css:1` — current single-line Tailwind source, the natural injection target
- `lib/preview/skeleton/app/views/layouts/application.html.erb:27` — minimal `<main>` chrome, no fonts/nav/flash
- `lib/preview/skeleton/Gemfile:18` — `tailwindcss-rails` gem
- `lib/preview/skeleton-overlay/config/initializers/preview_iframe.rb:1-14` — overlay pattern reference (ENV-driven)
- `app/jobs/execute_instruction_job.rb:35-79` — workspace init (skeleton + overlay copy → master.key → bundle → git commit)
- `app/jobs/execute_instruction_job.rb:131-186` — Roast subprocess invocation (how revision kwargs are passed)
- `app/controllers/projects_controller.rb:13-27` — project creation entry point
- `app/models/project.rb:45-54` — `current_state_prompt` (the only project-derived value reaching the LLM today)
- `db/schema.rb:116-126` — Project columns (no design fields)
- `app/agents/generator_agent.rb:4` — chat-layer system prompt (no styling)
- `app/prompts/create_plan_system.md:6` — planner mentions Tailwind exists, no styling guidance
- `lib/roast/revision_workflow.rb:141-194` — W2.2 prompt builder (the styling-injection point)
- `lib/roast/revision_workflow.rb:182-192` — Rules block; line 185 is the entire styling directive today
- `lib/roast/revision_workflow.rb:153-166` — workspace snapshot (lists controllers/models, NOT views)
- `app/assets/tailwind/application.css:9-105` — Hifumi `:root` token block (60 vars, reference shape)
- `app/assets/tailwind/application.css:110-736` — Hifumi component classes (55, reference shape)
- `app/views/layouts/application.html.erb:18-21` — Hifumi font CDN imports (reference shape)
- `docs/02-architecture/04-design-system.md` — Hifumi reference doc (token table, anti-patterns, "how to add a component" guide)
- `bin/preview-regen-skeleton:1-43` — skeleton regeneration script (unaffected by design-system work)

## Architecture Documentation

**Workspace baseline composition (today)**:
```
project workspace = lib/preview/skeleton/.   (vanilla rails new --css tailwind)
                  + lib/preview/skeleton-overlay/.   (X-Frame-Options strip + entrypoint)
                  + per-project master.key
```

**Per-project parameterization channels (existing)**:
1. ENV var passed to the preview container — [`PreviewManager#run_container:249`](lib/preview/preview_manager.rb#L249) sets `PREVIEW_HOST` from `project.id`. Read at runtime inside the workspace by an overlay initializer.
2. Project's `current_state_prompt` interpolated into the GeneratorAgent system prompt at chat time.

There is no existing channel for passing project metadata into either (a) workspace files written at init time or (b) the W2 Roast subprocess kwargs. Adding one is a small extension of `init_rails_app` (file write) and the `roast` invocation arglist (extra kwarg).

**Single styling-injection point**: All current generated-app styling guidance flows through one line: `lib/roast/revision_workflow.rb:185`. Any expansion of that line is read by the LLM on every revision.

**Re-theming via tokens**: Hifumi proves the pattern — a token-driven CSS file re-skins by swapping `:root` and fonts. The 5 systems can share that exact shape: same semantic aliases (`--bg`, `--accent`, etc.), same component-class names, different palette/font/radius/spacing values per system.

## Historical Context (from thoughts/)

- [`docs/02-architecture/04-design-system.md`](docs/02-architecture/04-design-system.md) — Hifumi reference doc, including the "How to add a new component" and "How to add a new status verb" recipes. Sections: token table (lines 50-68), component-to-view inventory (lines 70-90), status vocabulary (92-110), voice rules (112-127), anti-patterns (129-144), extension recipes (146-173).
- CLAUDE.md "Design system: Hifumi" entry — defines the convention that all visible chrome uses tokens from `app/assets/tailwind/application.css` and never hardcodes hex values.
- No prior research docs in `thoughts/shared/research/` cover design systems for generated apps. This is a new vertical.

## Related Research

None. This is the first research note on design-systems-for-generated-apps. Closest adjacent work: the Hifumi rollout commit `6c9234d design: apply Hifumi design system across visible chrome` (2026-05-01) which established the token-driven pattern for the *generator's own UI*.

## Open Questions

These are decisions the implementation phase needs to make — surfacing them here, not answering them.

1. **Where do per-system files live?** Two shapes that fit the existing overlay pattern:
   - **Per-system overlay dirs** — `lib/design_systems/<name>/` (each containing `app/assets/tailwind/application.css` and a layout patch or font-imports snippet). `init_rails_app` copies the chosen one on top after the standard overlay. Cleanest separation, mirrors `skeleton-overlay/`.
   - **Templated write** — one shared CSS template with per-system token blocks, picked at workspace-init time and written into `app/assets/tailwind/application.css`. Less file duplication, more conditional logic.
2. **What component-class API do all 5 systems share?** A common vocabulary the LLM can rely on regardless of which system was randomly picked: `.btn/.btn--primary/...`, `.field-input`, `.card`, `.app-nav`, `.alert`, etc. Without a shared API the LLM can't generate consistent markup.
3. **How does the LLM learn the API?** Options: (a) expand the W2 Rules block with the token + class list, (b) write a `docs/design.md` into the workspace at init time and reference it from the Rules block, (c) both. Option (b) keeps the Rules block compact and gives the LLM something to read on demand.
4. **Does CreatePlan need to know about design?** Probably not for v1 — the planner emits feature revisions, the implementer styles them. But CreatePlan's "navigation menu" rule ([`app/prompts/create_plan_system.md:9`](app/prompts/create_plan_system.md#L9)) is a styling-adjacent decision; worth checking that planner-generated layout revisions cooperate with the design system.
5. **Layout/font handover**: fonts go in `app/views/layouts/application.html.erb`, but that file gets regenerated/edited by the LLM during plan execution (e.g., when adding a navbar). Either the design system needs to be applied via a partial the LLM is told to leave alone, or it needs to land in the layout *after* the LLM's edits, or the LLM needs to be told about the layout convention up front.
6. **Existing app's UI on first load**: until the LLM produces views, the user sees Rails' default welcome page, which won't be themed. This is the same as today and probably fine — the design system shows up the moment the first feature ships.
7. **Cyber theme wall-clock cost**: dark themes with custom fonts may need additional Tailwind utility coverage (e.g., colored focus rings, glow shadows) that aren't in the v4 default. May surface during implementation.
8. **Verification**: how do we verify a generated app actually applied the design system? Roast's W2.4 verify step doesn't run system tests on remote hosts (per memory `project_verify_no_system_tests`). Visual verification likely waits for Phase 3+ preview iframe inspection by hand.
