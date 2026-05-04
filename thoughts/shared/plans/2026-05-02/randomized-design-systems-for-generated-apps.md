---
date: 2026-05-02
author: Paweł Strzałkowski (drafted by Claude)
status: draft
research: thoughts/shared/research/2026-05-02/design-systems-randomized-application.md
---

# LLM-picked frontend templates for generated apps — implementation plan

## Overview

Generated apps today ship as bare Rails + bare Tailwind. Add **five frontend templates** (Cyber, Flower, Earth, Office, Kids) that an LLM picks for each project based on the user's prompt, copies into the workspace as `docs/frontend.md` (alongside the existing architecture/conventions/domain knowledge files), and instructs the implementer to follow when styling every view.

The chosen template is **memory in markdown**, not an attribute on `Project`. The user can later say "use these design elements" and the next revision updates `docs/frontend.md` like any other knowledge doc — same pattern as `architecture.md`, `conventions.md`, `domain.md` get updated at W2.6 (`update_docs`) today.

## Current State Analysis

Per the research at [`thoughts/shared/research/2026-05-02/design-systems-randomized-application.md`](../../research/2026-05-02/design-systems-randomized-application.md):

1. **Workspace baseline** is a vanilla `rails new --css tailwind` copy — `app/assets/tailwind/application.css` is `@import "tailwindcss";` and the layout has no fonts/nav/chrome ([`lib/preview/skeleton/`](../../../../lib/preview/skeleton/)).
2. **Knowledge files in the workspace** are written deterministically as empty stubs by `init_docs_baseline` ([`app/jobs/execute_instruction_job.rb:113`](../../../../app/jobs/execute_instruction_job.rb#L113)) — `architecture.md`, `conventions.md`, `domain.md`, `revision_notes.md`. They get filled by the W2.6 `update_docs` Haiku agent ([`lib/roast/revision_workflow.rb:280`](../../../../lib/roast/revision_workflow.rb#L280)) from the diff after each revision. The W2 prompt builder globs them into the manifest at [`revision_workflow.rb:142-145`](../../../../lib/roast/revision_workflow.rb#L142-L145).
3. **LLM prompt chain** carries one styling directive total: `"Tailwind CSS for styling"` at [`revision_workflow.rb:185`](../../../../lib/roast/revision_workflow.rb#L185). Implementer has no design vocabulary, no class snippets, no font information.
4. **Existing LLM call sites** (per memory `project_three_llm_call_sites`): `ChatRespondJob`, `ExecuteInstructionJob` (the W2 Roast subprocess), `CreatePlan::AdHocLLM`. Each threads the project owner's OpenRouter key. A picker becomes the **fourth** call site and must follow the same pattern.

## Desired End State

After this plan lands:

- Five templates exist on disk under `lib/templates/<name>/{frontend.md, fonts.html}`.
- Every new project, on first instruction, gets a template picked by a Haiku one-shot LLM call based on the user's project description. The pick happens once per project.
- The picked template's `frontend.md` is copied 1-1 into `workspace/docs/frontend.md`. Its `fonts.html` is injected into `workspace/app/views/layouts/application.html.erb` `<head>`. Both land in a single `docs: pick frontend template` commit.
- The W2 implementer reads `frontend.md` as part of the manifest each revision and follows the rule "style every view per `docs/frontend.md` — don't ship bare scaffolds."
- W2.6 `update_docs` keeps `frontend.md` in sync. If the user's later request changes design (e.g. "make it darker"), that revision modifies views + `frontend.md`, and the existing summarizer reflects further changes correctly.
- No `Project#design_system` column. The chosen template is recorded only in `docs/frontend.md`.

**How to verify**: Create a project described as "cyberpunk task tracker", another as "flower delivery shop", another as "Jira-like bug board". After the first revision lands for each, open `docs/frontend.md` — content matches Cyber / Flower / Office templates respectively. The preview iframe shows visibly different palettes/fonts/density per project.

### Key Discoveries

- The **`init_docs_baseline` → `update_docs` pattern** is the natural home for `frontend.md`: deterministic stub at init, LLM-filled afterwards. The picker mirrors `update_docs`'s shape (Haiku, structured output, side-effect-only — no chat coupling).
- ENV plumbing for the Roast subprocess already exists ([`lib/roast/workflow_env.rb`](../../../../lib/roast/workflow_env.rb)). For this plan we don't need new ENV — the picker writes a workspace file, and the W2 manifest glob already reads `docs/*.md`. Just extend the glob.
- Per memory `feedback_no_service_objects`, the picker module lives under `lib/templates/`, not `app/services/`.
- Per memory `project_three_llm_call_sites`, the picker must thread `project.user.profile.openrouter_api_key` through `RubyLLM.context { |c| c.openrouter_api_key = ... }`. Same pattern as [`app/services/create_plan/ad_hoc_llm.rb:14-19`](../../../../app/services/create_plan/ad_hoc_llm.rb#L14-L19).
- `docs/frontend.md` doesn't need a CSS-variable layer (`tokens.css`). Inline hex values inside Tailwind arbitrary-value brackets (`bg-[#00FFCC]`) keep the template self-contained and the implementer doesn't need to know about CSS variables. One layer of indirection, not two.

## What We're NOT Doing

- **No `design_system` column on Project**. The choice is prompt-derived, lives in `docs/frontend.md`. If we ever need it as a structured field (analytics, filtering), it can be backfilled by parsing the file's first line.
- **No tokens.css / CSS-variable layer**. Each template's `frontend.md` carries inline hex values inside Tailwind class strings. Adjusting a color = editing one string in `frontend.md`. Re-theming via CSS variables is a possible future refinement; not v1.
- **No shared component-class layer in CSS** (`.btn`, `.card`, etc.). The implementer uses Tailwind utilities + the class snippets in `frontend.md`. Class-name vocabulary is the LLM's choice.
- **No chat-agent or planner changes**. The picker is a one-shot inside `ExecuteInstructionJob`, invisible to the chat surface. CreatePlan is untouched.
- **No re-pick logic**. Picked once at first instruction, never re-picked. Subsequent design changes flow through revisions + the existing `update_docs`.
- **No system tests / visual regression tests** (per memory `project_verify_no_system_tests`). Visual confirmation is manual via the preview iframe.
- **No backfill for existing projects**. The picker is gated by `File.exist?("docs/frontend.md")` — old workspaces without the file get one written on their next instruction; old workspaces that somehow have one are left alone.
- **No skeleton regeneration**. `bin/preview-regen-skeleton` unaffected.

## Implementation Approach

Five atomic phases. Each is one commit, testable on its own, leaves the system working.

1. **Define the 5 templates on disk** — `lib/templates/<name>/{frontend.md, fonts.html}` + a `Templates` registry module. Pure additions; nothing reads them yet.
2. **`Templates::Picker` module** — the LLM call + workspace side effects (write `frontend.md`, inject fonts, git commit). Tested in isolation with a stubbed LLM.
3. **Wire picker into `ExecuteInstructionJob`** — runs after `init_docs_baseline`, idempotent on `docs/frontend.md` existence.
4. **Surface `frontend.md` to the implementer** — extend W2 manifest glob + add "style every view per `docs/frontend.md`" rule.
5. **Keep `frontend.md` in sync via `update_docs`** — extend W2.6's allowed-paths and prompt to include `frontend.md`.

Phases 4 and 5 both edit `revision_workflow.rb` but at different agents (`generate_code` vs `update_docs`); kept separate so each commit has a single concern.

---

## Phase 1: Define the 5 frontend templates on disk

### Commit
`templates: add five frontend templates (cyber, flower, earth, office, kids)`

### Overview
Pure additions: each template is a directory with two files. Plus a small registry module that loads them. Nothing consumes these yet.

### Changes Required

#### 1. Directory layout
**Path**: `lib/templates/<name>/` for each of `cyber flower earth office kids`.

Each contains:
- `frontend.md` — the markdown that gets copied 1-1 into `workspace/docs/frontend.md`. Hybrid content: a prose **Vibe** section (palette, fonts, density, voice), then a **Class snippets** section with concrete Tailwind class strings for canonical primitives (button, input/label, card, app-shell + nav, alert, list/table). Inline hex values; no CSS variables.
- `fonts.html` — Google Fonts `<link>` tags.

#### 2. Template content sketch

Each `frontend.md` follows this shape (**50-100 lines TOPS** — this file is in the W2 manifest on every revision, so every line is a per-revision token cost):

```markdown
# Frontend template: <name>

## Vibe

(2-4 sentences — palette + voice + density + corner language. Tight, no fluff.)

## Fonts

- Display/headings: <font 1>
- Body: <font 2>
- (serif / mono / etc. as relevant)

The font `<link>` is already loaded in `app/views/layouts/application.html.erb`.

## Class snippets

Five primitives. One snippet each — the implementer can derive variants (secondary / danger / ghost button, list rows, etc.) from the primary snippet's vocabulary.

### Button (primary)
```erb
<%= button_tag "Save", class: "<concrete tailwind classes with inline hex>" %>
```

### Form field (label + input)
(label + input together, with focus + error states inline)

### Card
(container + heading + body)

### App shell + top nav
(container max-width, nav bar markup)

### Alert
(one snippet covering the four states via swappable color classes — don't write four)

## Layout density

- Container max-width / default page padding / vertical rhythm — one line each.

## Voice

(2-3 lines — sentence-case vs. title-case, copy register, allowed/banned ornament.)
```

The snippet inventory is intentionally minimal. Earlier draft listed 7+ primitives with 3-4 button variants each — that pushed the file past 200 lines and burns input tokens on every W2 prompt build with diminishing return. A good Cyber-button snippet teaches the implementer the vocabulary; it doesn't need to enumerate every variant.

Concrete content per template:

**Cyber** — dark, terminal, neon. Backgrounds near-black (`#07090E`), accents neon cyan (`#00FFCC`). Sharp corners (`rounded-none` or `rounded-sm`). Mono everywhere except headings. Uppercase tracked labels. `>` prefix for menu items. Optional glow shadows.

**Flower** — pastel, soft, decorative. Pinks/lavenders (`#FFF5F7`, `#E8639E`). Quicksand body, Playfair Display headings. Generous padding, `rounded-2xl` cards, soft drop shadows, decorative dividers, title-case headings.

**Earth** — muted, mellow, low-contrast. Sage/clay/sand (`#F5F0E8`, `#6B7F5F`). Source Serif 4 body, Roboto Slab headings. `rounded-md`, low-contrast accent, warm off-whites, no harsh borders.

**Office** — JIRA-like, professional, dense. Navy/grey/white (`#F4F5F7`, `#0052CC`). Inter throughout. Sharp corners (`rounded-sm`), narrow row heights, dense form layouts, restrained color, hover states with `bg-blue-50`.

**Kids** — bright, bold, playful. Primary red/blue/yellow on cream (`#FFFCEE`). Fredoka body, Lilita One headings. Thick black borders (`border-2 border-black`), big radii (`rounded-2xl`), playful offset shadows (`shadow-[4px_4px_0_#1A1A1A]`), bright primary fills.

Each `fonts.html` is the matching set of Google Fonts `<link>` tags (preconnect + stylesheet).

#### 3. Registry module
**File**: `lib/templates.rb` (and `lib/templates/template.rb` if it grows; for v1 a single file is fine).
**Changes**: New module, namespace-only.

```ruby
module Templates
  NAMES = %w[cyber flower earth office kids].freeze

  Template = Struct.new(:name, :frontend_md, :fonts_html, keyword_init: true)

  def self.find(name)
    raise ArgumentError, "unknown template: #{name.inspect}" unless known?(name)
    Template.new(
      name: name,
      frontend_md: File.read(root.join(name, "frontend.md")),
      fonts_html:  File.read(root.join(name, "fonts.html"))
    )
  end

  def self.known?(name)
    return false if name.to_s.empty?
    NAMES.include?(name) && root.join(name).directory?
  end

  def self.root
    Rails.root.join("lib/templates")
  end
end
```

#### 4. Tests
**File**: `test/lib/templates_test.rb`
**Changes**: New test file.

```ruby
require "test_helper"

class TemplatesTest < ActiveSupport::TestCase
  test "all five templates load with non-empty frontend.md and fonts.html" do
    Templates::NAMES.each do |name|
      tpl = Templates.find(name)
      assert_equal name, tpl.name
      assert_predicate tpl.frontend_md, :present?, "#{name} frontend.md must be non-empty"
      assert_predicate tpl.fonts_html,  :present?, "#{name} fonts.html must be non-empty"
    end
  end

  test "every frontend.md contains the canonical sections" do
    required = ["## Vibe", "## Class snippets", "## Fonts"]
    Templates::NAMES.each do |name|
      md = Templates.find(name).frontend_md
      required.each do |section|
        assert_includes md, section, "#{name}/frontend.md must have a '#{section}' section"
      end
    end
  end

  test "every fonts.html references fonts.googleapis.com" do
    Templates::NAMES.each do |name|
      assert_match %r{fonts\.googleapis\.com}, Templates.find(name).fonts_html,
                   "#{name}/fonts.html must reference fonts.googleapis.com"
    end
  end

  # frontend.md is in the W2 manifest on every revision — every line is a
  # per-revision token cost. Cap at 100 to stop drift; warn at 50 if too thin.
  test "every frontend.md is between 30 and 100 lines" do
    Templates::NAMES.each do |name|
      lines = Templates.find(name).frontend_md.lines.size
      assert_operator lines, :<=, 100, "#{name}/frontend.md is #{lines} lines — cap is 100"
      assert_operator lines, :>=, 30,  "#{name}/frontend.md is #{lines} lines — looks too thin"
    end
  end

  test "find raises ArgumentError for unknown name" do
    assert_raises(ArgumentError) { Templates.find("brutalist") }
    assert_raises(ArgumentError) { Templates.find("") }
  end

  test "known? returns false for blank or unknown names" do
    refute Templates.known?("")
    refute Templates.known?(nil)
    refute Templates.known?("brutalist")
    Templates::NAMES.each { |n| assert Templates.known?(n) }
  end
end
```

### Success Criteria

#### Automated Verification
- [x] All ten files exist: `ls lib/templates/{cyber,flower,earth,office,kids}/{frontend.md,fonts.html}` returns 10 paths
- [x] Registry tests pass: `bin/rails test test/lib/templates_test.rb` (6 runs / 95 assertions / 0 failures)
- [x] Full suite green: `bin/rails test` (only pre-existing Preview::PreviewManagerTest failures, present on main pre-change)

#### Manual Verification
- [ ] Read each `frontend.md` aloud — sounds like coherent style guidance, not a token dump.
- [ ] **Each `frontend.md` is 50-100 lines** (`wc -l lib/templates/*/frontend.md`). Anything over 100 gets cut — this file lands in the W2 manifest on every revision and bloat compounds.
- [ ] Class snippets look copy-pastable into ERB views (parseable Tailwind utilities; no broken angle brackets).
- [ ] Confirm all five `fonts.html` files have `preconnect` + `stylesheet` `<link>` tags.

**Implementation Note**: Pause for manual confirmation before proceeding.

---

## Phase 2: `Templates::Picker` — LLM-driven template selection + workspace side effects

### Commit
`templates: add Templates::Picker (Haiku one-shot, writes frontend.md, injects fonts)`

### Overview
A module that:
1. Takes a project description + workspace path + OpenRouter key.
2. Calls Haiku via RubyLLM with structured output, asking it to pick one of the 5 template names based on the description.
3. Copies the picked template's `frontend.md` into `workspace/docs/frontend.md`.
4. Injects the picked template's `fonts.html` into `workspace/app/views/layouts/application.html.erb` `<head>`.
5. Commits both changes.

Tested in isolation with a stubbed LLM call. Not yet wired into any job.

### Changes Required

#### 1. Picker module
**File**: `lib/templates/picker.rb`
**Changes**: New module.

```ruby
require "shellwords"

module Templates
  module Picker
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a frontend template picker. Given a user's plain-language project description, pick the single best-fit template from this fixed list:

      - cyber  — dark, neon, terminal/cyberpunk feel, monospace, sharp corners
      - flower — pastel, soft, decorative; suits boutiques, lifestyle, wellness, weddings
      - earth  — muted, warm, low-contrast; suits journals, blogs, slow-living, content
      - office — clean professional like Jira/Linear; suits dashboards, internal tools, B2B
      - kids   — bright, playful, bold borders; suits children's apps, games, learning, fun

      If nothing fits cleanly, pick the closest. Never invent names. Output exactly the JSON schema requested.
    PROMPT

    SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["template", "reasoning"],
      "properties" => {
        "template"  => { "type" => "string", "enum" => Templates::NAMES },
        "reasoning" => { "type" => "string", "maxLength" => 200 }
      }
    }.freeze

    MODEL = "anthropic/claude-haiku-4.5"

    class InvalidPick < StandardError; end

    # Pick + apply side effects. Returns the chosen template name.
    def self.call(workspace:, description:, openrouter_api_key:)
      name = pick(description: description, openrouter_api_key: openrouter_api_key)
      apply(workspace: workspace, name: name)
      name
    end

    def self.pick(description:, openrouter_api_key:)
      ctx = RubyLLM.context { |c| c.openrouter_api_key = openrouter_api_key }
      chat = ctx.chat(model: MODEL)
      chat.with_instructions(SYSTEM_PROMPT)
      content = chat.with_schema(SCHEMA).ask("Description: #{description}").content
      name = content.is_a?(Hash) ? content["template"] : nil
      raise InvalidPick, "picker returned #{content.inspect}" unless Templates::NAMES.include?(name)
      name
    end

    def self.apply(workspace:, name:)
      tpl = Templates.find(name)

      frontend_path = File.join(workspace, "docs/frontend.md")
      FileUtils.mkdir_p(File.dirname(frontend_path))
      File.write(frontend_path, tpl.frontend_md)

      layout_path = File.join(workspace, "app/views/layouts/application.html.erb")
      layout = File.read(layout_path)
      raise "layout missing </head>" unless layout.include?("</head>")
      File.write(layout_path, layout.sub("</head>", "    #{tpl.fonts_html.strip}\n  </head>"))

      ok = system(
        "cd #{Shellwords.escape(workspace)} && git add docs/frontend.md app/views/layouts/application.html.erb && " \
        "git -c user.email=generator@local -c user.name='Rails App Generator' " \
        "commit -q -m 'docs: pick frontend template (#{name})'"
      )
      raise "git commit failed in #{workspace}" unless ok
    end
  end
end
```

The `pick` and `apply` are public so tests can exercise them independently. `call` is the one-shot front door used by `ExecuteInstructionJob` in Phase 3.

#### 2. Tests
**File**: `test/lib/templates/picker_test.rb`
**Changes**: New test file. Stubs the LLM call by injecting a result into `pick`.

```ruby
require "test_helper"

class Templates::PickerTest < ActiveSupport::TestCase
  # --- pick: LLM stubbed via mock on the chat object -------------------

  test "pick returns the name when LLM responds with a known template" do
    stub_pick("cyber") do
      assert_equal "cyber", Templates::Picker.pick(description: "neon hacker tracker", openrouter_api_key: "sk-test")
    end
  end

  test "pick raises InvalidPick when LLM returns an unknown name" do
    stub_pick("brutalist") do
      assert_raises(Templates::Picker::InvalidPick) do
        Templates::Picker.pick(description: "x", openrouter_api_key: "sk-test")
      end
    end
  end

  test "pick raises InvalidPick when LLM returns nil/non-hash content" do
    stub_pick(nil) do
      assert_raises(Templates::Picker::InvalidPick) do
        Templates::Picker.pick(description: "x", openrouter_api_key: "sk-test")
      end
    end
  end

  # --- apply: workspace side effects -----------------------------------

  test "apply writes docs/frontend.md with the template's content" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "cyber")
      written = File.read(File.join(ws, "docs/frontend.md"))
      assert_equal Templates.find("cyber").frontend_md, written
    end
  end

  test "apply injects fonts.html before </head> in the layout" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "flower")
      layout = File.read(File.join(ws, "app/views/layouts/application.html.erb"))
      assert_match %r{fonts\.googleapis\.com}, layout
      assert_match %r{</head>}, layout, "must keep </head> intact"
      head_idx = layout.index("</head>")
      flower_idx = layout.index("Quicksand") || layout.index("fonts.googleapis.com")
      assert flower_idx < head_idx, "fonts must be injected BEFORE </head>"
    end
  end

  test "apply raises when layout has no </head> tag" do
    in_workspace do |ws|
      File.write(File.join(ws, "app/views/layouts/application.html.erb"), "<html><body></body></html>")
      assert_raises(RuntimeError) { Templates::Picker.apply(workspace: ws, name: "earth") }
    end
  end

  test "apply commits both files with the expected message" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "office")
      msg = `cd #{Shellwords.escape(ws)} && git log -1 --pretty=%s`.strip
      assert_equal "docs: pick frontend template (office)", msg

      changed = `cd #{Shellwords.escape(ws)} && git show --name-only --pretty=format: HEAD`.split("\n").reject(&:empty?).sort
      assert_equal %w[app/views/layouts/application.html.erb docs/frontend.md], changed
    end
  end

  # --- helpers ---------------------------------------------------------

  private

  # Build a minimal git-initialized workspace with the layout file present.
  def in_workspace
    Dir.mktmpdir("templates-picker-test-") do |ws|
      FileUtils.mkdir_p(File.join(ws, "app/views/layouts"))
      File.write(
        File.join(ws, "app/views/layouts/application.html.erb"),
        "<!DOCTYPE html>\n<html>\n  <head>\n    <title>x</title>\n  </head>\n  <body></body>\n</html>"
      )
      Dir.chdir(ws) do
        system("git init -q && git add -A && " \
               "git -c user.email=t@t -c user.name=t commit -q -m baseline")
      end
      yield ws
    end
  end

  # Stub Templates::Picker.pick's LLM call by replacing the chat object's
  # `with_schema(...).ask(...).content` chain. Uses RubyLLM::Context interface.
  def stub_pick(value)
    fake_content = value.nil? ? nil : { "template" => value, "reasoning" => "stub" }
    fake_chat = Object.new
    fake_chat.define_singleton_method(:with_instructions) { |_| self }
    fake_chat.define_singleton_method(:with_schema)       { |_| self }
    fake_chat.define_singleton_method(:ask)               { |_| Struct.new(:content).new(fake_content) }

    fake_ctx = Object.new
    fake_ctx.define_singleton_method(:chat) { |**| fake_chat }

    RubyLLM.stub(:context, ->(&_block) { fake_ctx }) { yield }
  end
end
```

The stub mirrors the real RubyLLM chain (`context → chat → with_instructions → with_schema → ask → content`). If the actual call shape evolves, this test is the canary.

### Success Criteria

#### Automated Verification
- [x] Picker tests pass: `bin/rails test test/lib/templates/picker_test.rb` (7 runs / 12 assertions / 0 failures)
- [x] Full suite green: `bin/rails test` (256 runs, only the same pre-existing Preview::PreviewManagerTest failures)

#### Manual Verification
- [x] Run picker in console against five real descriptions — Haiku picked the expected template for every one:
  - "cyberpunk task tracker for hackers" → `cyber` ✓
  - "wedding florist boutique with online ordering" → `flower` ✓
  - "slow-living journal for personal essays" → `earth` ✓
  - "internal bug tracker like Jira for our engineering team" → `office` ✓
  - "math game app for 6-year-olds" → `kids` ✓
- [x] `docs/frontend.md` written and `fonts.googleapis.com` injected into layout for every run.

**Implementation Note**: Pause for manual confirmation before proceeding.

---

## Phase 3: Wire `Templates::Picker` into `ExecuteInstructionJob`

### Commit
`templates: pick frontend template at workspace init`

### Overview
After `init_docs_baseline`, run `Templates::Picker.call` if `docs/frontend.md` doesn't already exist. Idempotent — safe to re-enter on retries. Uses the project owner's OpenRouter key (same as `execute_revision`).

### Changes Required

#### 1. Job edit
**File**: `app/jobs/execute_instruction_job.rb`
**Changes**: Add a `pick_frontend_template` step in `perform`, and a private method that delegates to `Templates::Picker`.

```ruby
def perform(instruction_id)
  instruction = Instruction.find(instruction_id)
  project = instruction.project
  workspace = project.workspace_path

  prepare_workspace(workspace)                   unless project.workspace_initialized?
  init_rails_app(workspace)                      unless File.exist?(File.join(workspace, "Gemfile"))
  init_docs_baseline(workspace)                  unless File.exist?(File.join(workspace, "docs"))
  pick_frontend_template(workspace, instruction) unless File.exist?(File.join(workspace, "docs/frontend.md"))

  # ... existing revisions loop ...
end

private

def pick_frontend_template(workspace, instruction)
  api_key = instruction.project.user.profile.openrouter_api_key
  raise "Project owner has no OpenRouter API key" if api_key.blank?

  # `user_intent` is what the chat agent passed to start_generation — the
  # synthesis of the user's initial description plus any clarifications it
  # gathered. Substantive signal (typically 1-3 sentences). Fall back to
  # project.name (truncate(60) of the first message) if user_intent is blank,
  # which can happen if the agent skipped clarifications and the chat input
  # was very short.
  description = instruction.user_intent.presence || instruction.project.name

  Templates::Picker.call(
    workspace: workspace,
    description: description,
    openrouter_api_key: api_key
  )

  # Picker writes a NEW file (docs/frontend.md) and rewrites the layout as
  # root. Without this relax, the `claude` agent in W2.6 update_docs (running
  # as the `generator` user) gets EACCES the first time it tries to Edit
  # frontend.md. Mirrors what init_rails_app and init_docs_baseline already do.
  relax_workspace_permissions(workspace)
end
```

`instruction.user_intent` is set by `StartGeneration#execute` ([`app/tools/start_generation.rb:36`](../../../../app/tools/start_generation.rb#L36)) from the `intent:` param the chat agent constructs after the clarification round-trip. Much richer than the 60-char `project.name`.

#### 2. Tests
**File**: `test/jobs/execute_instruction_job_test.rb`
**Changes**: Add tests covering: idempotent skip when `frontend.md` exists, invocation with the right args, gating on workspace_initialized state.

```ruby
test "perform calls Templates::Picker.call with instruction.user_intent" do
  @instruction.update!(user_intent: "neon hacker dashboard for tracking exploits")

  picker_calls = []
  Templates::Picker.stub(:call, ->(**args) { picker_calls << args }) do
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do
      ExecuteInstructionJob.perform_now(@instruction.id)
    end
  end

  assert_equal 1, picker_calls.size
  call = picker_calls.first
  assert_equal @project.workspace_path, call[:workspace]
  assert_equal "neon hacker dashboard for tracking exploits", call[:description]
  assert_equal "sk-or-test-fixture-1234567890ab", call[:openrouter_api_key]
end

test "perform falls back to project.name when instruction.user_intent is blank" do
  @instruction.update!(user_intent: "")

  picker_calls = []
  Templates::Picker.stub(:call, ->(**args) { picker_calls << args }) do
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do
      ExecuteInstructionJob.perform_now(@instruction.id)
    end
  end

  assert_equal @project.name, picker_calls.first[:description]
end

test "perform skips Templates::Picker when docs/frontend.md already exists" do
  ws = @project.workspace_path
  FileUtils.mkdir_p(File.join(ws, "docs"))
  File.write(File.join(ws, "Gemfile"), "")
  File.write(File.join(ws, "docs/frontend.md"), "# already picked\n")

  picker_called = false
  Templates::Picker.stub(:call, ->(**) { picker_called = true }) do
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do
      ExecuteInstructionJob.perform_now(@instruction.id)
    end
  end

  refute picker_called, "picker must not run when frontend.md is already present"
ensure
  FileUtils.rm_rf(@project.workspace_path)
end

test "pick_frontend_template raises when project owner has no OpenRouter key" do
  @user.profile.update_columns(openrouter_api_key: nil)
  assert_raises(RuntimeError) do
    ExecuteInstructionJob.new.send(:pick_frontend_template, @project.workspace_path, @instruction)
  end
end
```

Update the existing "skips prepare_workspace + init_rails_app + init_docs_baseline" test to also cover that `pick_frontend_template` skips when `docs/frontend.md` exists.

### Success Criteria

#### Automated Verification
- [x] Job tests pass: `bin/rails test test/jobs/execute_instruction_job_test.rb` (27 runs / 90 assertions / 0 failures)
- [x] Full suite green: `bin/rails test` (260 runs, only pre-existing Preview::PreviewManagerTest failures)

#### Manual Verification
- [x] Smoke ran `pick_frontend_template` end-to-end against a real workspace + real Haiku call (description "internal bug tracker like Jira"). Confirmed:
  - `docs/frontend.md` exists, first line `# Frontend template: office` ✓
  - Layout injected `fonts.googleapis.com` link ✓
  - Git log shows `docs: pick frontend template (office)` between baseline and any later commits ✓
- [x] Idempotency at the public call site (perform) is enforced by the `unless File.exist?(File.join(workspace, "docs/frontend.md"))` gate; covered by the test `"skips prepare_workspace + init_rails_app + init_docs_baseline + pick_frontend_template when already initialized"`.

**Implementation Note**: Pause for manual confirmation before proceeding.

---

## Phase 4: Surface `frontend.md` to the implementer agent

### Commit
`roast: feed frontend.md into W2 manifest and rules block`

### Overview
The W2 prompt builder globs `docs/{architecture,conventions,domain}.md` into the manifest. Extend the glob to include `frontend.md`. Add a Rules-block line instructing the implementer to follow it and not ship bare scaffolds.

### Changes Required

#### 1. Manifest glob
**File**: `lib/roast/revision_workflow.rb`
**Changes**: At the existing manifest glob (~line 143):

```ruby
manifest = Dir.glob("#{docs_dir}/{architecture,conventions,domain,frontend}.md")
              .map { |f| "### #{File.basename(f)}\n\n#{File.read(f)}" }
              .join("\n\n")
```

#### 2. Rules block
**File**: `lib/roast/revision_workflow.rb`
**Changes**: At the Rules block (~line 182), after the existing `Tailwind CSS for styling` line:

```ruby
parts << <<~RULES
  ## Rules
  - Rails Way: conventions, generators, built-in solutions
  - Tailwind CSS for styling
  - Follow `docs/frontend.md` (palette, fonts, density, class snippets) for every view. Don't ship default Rails scaffold markup or unstyled forms — apply the template's class snippets to buttons, inputs, cards, navs, alerts. Inline hex values in arbitrary-value brackets (`bg-[#00FFCC]`) are fine.
  - Hotwire (Turbo + Stimulus), no React/Vue
  - Minitest, not RSpec
  - Write tests for new functionality
  - Don't create empty directories or files that aren't needed
  - You are working in #{WORKSPACE} — all paths are relative to this directory
  - The snapshot above is current. Don't glob or list directories to discover what already exists; only read a specific file when you actually need its contents to make the change.
RULES
```

#### 3. Tests
**File**: `test/lib/roast/revision_workflow_test.rb` (or wherever build_prompt is unit-tested today; create if absent — see existing `test/lib/` layout).
**Changes**: Cover the glob extension. The Rules-block prose change is hard to unit-test (workflow loads at runtime); covered via manual verification.

If a `build_prompt` unit test exists today, add a case:

```ruby
test "build_prompt manifest includes frontend.md when present" do
  in_fake_workspace do |ws|
    File.write(File.join(ws, "docs/frontend.md"), "# Frontend\n\nVibe: cyber.\n")
    prompt = run_build_prompt(ws, summary: "x", prompt: "y")
    assert_includes prompt, "### frontend.md"
    assert_includes prompt, "Vibe: cyber."
  end
end
```

If no such test scaffolding exists, the manual smoke (running a real revision and reading the logged prompt) is the verification path. Note this in the manual-verification list.

### Success Criteria

#### Automated Verification
- [x] No existing `build_prompt` unit-test harness — workflow file abort()s at top-level on missing env, would need a substantial new harness for one assertion. Skipped per plan ("manual smoke is the verification path"). Did do a programmatic glob check: `Dir.glob("docs/{architecture,conventions,domain,frontend}.md")` against project 8's workspace returns all four files including frontend.md ✓.
- [x] Full suite green: `bin/rails test` (260 runs, only pre-existing Preview failures)

#### Manual Verification
- [ ] Run a real revision on a project that has `docs/frontend.md`. Inspect the Roast subprocess logs (scrubbed by `Rails.logger.info`) — the prompt contains `### frontend.md` block and the new Rules line.
- [ ] After the revision lands, the produced views use the template's palette + fonts + class snippets (preview iframe).
- [ ] Spot-check at least three of the five templates by creating fresh projects with descriptions that should steer to those templates.

**Implementation Note**: Pause for manual confirmation before proceeding.

---

## Phase 5: Keep `frontend.md` in sync via `update_docs`

### Commit
`roast: include frontend.md in update_docs scope`

### Overview
W2.6 `update_docs` (Haiku) currently summarizes diffs into `architecture.md` / `conventions.md` / `domain.md` / `revision_notes.md`. Extend the prompt so it also keeps `frontend.md` in sync — when a revision adds/changes design (new color, new component pattern, user-driven design tweak), `frontend.md` reflects it.

The agent's `--tools` allow-list is `Edit,Read` ([`revision_workflow.rb:54`](../../../../lib/roast/revision_workflow.rb#L54)); no permission change needed. Just prompt-side scope.

### Changes Required

#### 1. update_docs prompt
**File**: `lib/roast/revision_workflow.rb`
**Changes**: At the W2.6 `agent(:update_docs)` block (~lines 280-316):

```ruby
<<~PROMPT
  Revision "#{kwarg(:revision_summary)}" was just committed. Update the docs in docs/ to reflect it.

  ## What changed (git show HEAD)

  ```
  #{diff_stat}
  ```

  ```
  #{diff_body}
  ```

  ## Your task

  1. `architecture.md` — models, relations, key controllers, routing (touch only what changed)
  2. `conventions.md` — decisions made, gems used, patterns (touch only what changed)
  3. `domain.md` — domain glossary, business rules (touch only what changed)
  4. `frontend.md` — design template + class snippets. Touch ONLY if this revision changed styling decisions (new palette, new component pattern, user-driven design tweak). NEVER touch if styling didn't change. NEVER replace the entire file — small edits to the relevant snippet section.
  5. `revision_notes.md` — APPEND a short section for this revision:
     - What implementation decisions you made and WHY (not a summary)

  ## Rules — IMPORTANT, read carefully

  - Work from the diff above. Do NOT glob, do NOT read the workspace tree, do NOT inspect git history.
  - The only file reads allowed are these five exact paths: `docs/architecture.md`, `docs/conventions.md`, `docs/domain.md`, `docs/frontend.md`, `docs/revision_notes.md`. Do not read the `docs/` directory itself — read the file paths directly.
  - Use Edit (small, targeted edits) or append-only operations. Do not rewrite whole files.
  - If a doc has nothing to update for this revision, skip it — don't write filler.
  - Be terse. Each section in revision_notes is 1-3 sentences max.
PROMPT
```

The "NEVER touch if styling didn't change" guard is load-bearing — most revisions will be backend/feature work where `frontend.md` should be left alone, and a Haiku that drifts into "let me also tweak the button color while I'm here" would be a mess.

#### 2. Tests
The update_docs prompt is constructed from runtime values (the diff) and not unit-tested today. The change is prose-only. Verification is manual.

### Success Criteria

#### Automated Verification
- [x] Full suite green: `bin/rails test` (260 runs, only pre-existing Preview failures)

#### Manual Verification
- [ ] Run a feature revision (no styling change) on a project with `frontend.md`. Confirm the post-revision `git log` shows `docs: update manifest and revision notes` but `docs/frontend.md` is unchanged in that commit (`git show HEAD -- docs/frontend.md` is empty).
- [ ] Run a styling revision (e.g. user message: "make all primary buttons rounder"). Confirm `docs/frontend.md`'s primary-button class snippet got updated by `update_docs` — and the class strings used in the actual ERB views match the new snippet.
- [ ] Confirm `frontend.md` doesn't get rewritten wholesale — diffs are small and targeted.

**Implementation Note**: This is the final phase. Manual confirmation closes the work.

---

## Testing Strategy

### Unit Tests
- `Templates::NAMES` lookup, `find` happy/error paths, `known?` predicate (Phase 1).
- `Templates::Picker.pick` LLM-result handling (happy / unknown / nil) via stubbed RubyLLM chain (Phase 2).
- `Templates::Picker.apply` workspace side effects: file write, layout injection, missing-`</head>` raise, git commit (Phase 2).
- `ExecuteInstructionJob#pick_frontend_template` invocation, idempotency, missing-key raise (Phase 3).
- `revision_workflow.rb` manifest glob includes `frontend.md` if a build_prompt unit test exists (Phase 4).

### Integration Tests
The existing `test/integration/generate_todo_list_test.rb` (gated by `E2E_GENERATE=1`) exercises the full chain. After this plan it will also exercise `Templates::Picker` — needs an OpenRouter key. The test should still pass; if Haiku's pick is non-deterministic, the test asserts only that *some* `frontend.md` exists post-init, not which template was picked.

### Manual Testing Steps
1. Create five fresh projects in dev with descriptions that steer toward each template:
   - "neon hacker dashboard" → expect `cyber`
   - "wedding florist site" → expect `flower`
   - "slow-living journal" → expect `earth`
   - "internal bug tracker like Jira" → expect `office`
   - "kids' math game" → expect `kids`
2. Run a full generation per project. Open each preview iframe; confirm visually distinct identities.
3. For one project, send a follow-up: "make the primary color teal instead." Run a generation. Confirm `frontend.md` now records teal AND views render teal primary buttons.
4. Inspect `docs/` in three workspaces — `frontend.md` is present, populated, and matches one of `lib/templates/*/frontend.md`.

## Performance Considerations

- One additional Haiku call per project (one-shot at first instruction). Negligible cost (~$0.001 per pick).
- W2 prompt grows by `frontend.md`'s length (target: 50-100 lines, ~400-800 input tokens) every revision. This is a per-revision cost on every project for the lifetime of the project, so the cap matters — keep templates lean. Comparable in size to existing manifest items (architecture/conventions/domain).
- Workspace init grows by one git commit. Negligible vs `bundle install`.

## Migration Notes

- Existing projects without `docs/frontend.md` get one written on their next instruction. Their layout doesn't get retro-fitted with font links until that next instruction triggers `pick_frontend_template`. If retroactive fixing is desired later, a small backfill task can iterate `Project.all` and run `Templates::Picker.call(...)` on each workspace whose `frontend.md` is missing.
- No DB migrations.

## References

- Research: [`thoughts/shared/research/2026-05-02/design-systems-randomized-application.md`](../../research/2026-05-02/design-systems-randomized-application.md)
- Existing precedent (`init_docs_baseline` → `update_docs`): [`app/jobs/execute_instruction_job.rb:113`](../../../../app/jobs/execute_instruction_job.rb#L113), [`lib/roast/revision_workflow.rb:280`](../../../../lib/roast/revision_workflow.rb#L280)
- Existing LLM call pattern with OpenRouter key threading: [`app/services/create_plan/ad_hoc_llm.rb:14-19`](../../../../app/services/create_plan/ad_hoc_llm.rb#L14-L19)
- W2 manifest glob (extension target): [`lib/roast/revision_workflow.rb:142-145`](../../../../lib/roast/revision_workflow.rb#L142-L145)
- W2 Rules block (extension target): [`lib/roast/revision_workflow.rb:182-192`](../../../../lib/roast/revision_workflow.rb#L182-L192)
- Layout injection target: [`lib/preview/skeleton/app/views/layouts/application.html.erb:23-24`](../../../../lib/preview/skeleton/app/views/layouts/application.html.erb#L23-L24)
- Memory `feedback_no_service_objects` — picker lives in `lib/templates/`, not `app/services/`.
- Memory `project_three_llm_call_sites` — picker is the fourth call site, threads OpenRouter key the same way.
