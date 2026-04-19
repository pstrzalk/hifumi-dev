# Phase 2 Step 4 Refinement: `PlanSchema` + `with_schema` Implementation Plan

## Overview

Replace the forced-tool-call structured-output hack in `CreatePlan::AdHocLLM` with the canonical RubyLLM pattern for typed JSON: `RubyLLM::Schema` + `chat.with_schema(...).ask(...)`. This is Finding 2 of the 2026-04-19 RubyLLM 1.14.1 canonical audit. Scope is strictly "make canonical per RubyLLM" — no behavior change, no API change, no adjacent cleanup.

## Current State Analysis

`app/services/create_plan/ad_hoc_llm.rb:8-76` defines a `RubyLLM::Tool` subclass `EmitPlan` with a `params` DSL, instantiates it, forces the model to call it via `chat.with_tool(tool, choice: :required)`, captures the arguments in an `@captured` ivar inside `execute`, `halt`s to skip the follow-up turn, and extracts the captured Hash afterwards. Because RubyLLM symbolizes top-level tool args but leaves nested hashes string-keyed, a `fetch_any` helper (lines 72-76) patches the mixed-key access.

This works. It's not canonical. The skill (`references/structured-output.md:152-159`) maps "typed JSON answer once" to `with_schema`; tools are for "model calls your code mid-conversation." Nothing in `CreatePlan::AdHocLLM` is mid-conversation — the tool exists only to force the output shape.

Downstream:
- `app/services/create_plan.rb` — facade delegating to `AdHocLLM.call`.
- `app/tools/start_generation.rb:58` — rescues `CreatePlan::AdHocLLM::InvalidResponse`.
- `test/services/create_plan/ad_hoc_llm_test.rb` — stubs `invoke_llm` to return a pre-called tool.
- `test/fixtures/files/create_plan/*.json` — shape-only fixtures, provider-agnostic; already the string-keyed `JSON.parse` shape that `response.content` returns.

The empty `app/schemas/` folder (created by `ruby_llm:install`, currently only `.gitkeep`) is where `PlanSchema` belongs.

## Desired End State

- `app/schemas/plan_schema.rb` exists with `PlanSchema < RubyLLM::Schema` mirroring the current `params` DSL 1:1.
- `app/services/create_plan/ad_hoc_llm.rb` uses `chat.with_schema(PlanSchema).ask(user_prompt).content`; the `EmitPlan` tool class and `fetch_any` helper are gone.
- `app/prompts/create_plan_system.md` no longer mentions the `emit_plan` tool (two mechanical line edits).
- `test/services/create_plan/ad_hoc_llm_test.rb` stubs `invoke_llm` to return a Hash; all 9 test cases still pass, preserving their intent.
- Public API of `CreatePlan::AdHocLLM` unchanged (`.call` signature, `CreatePlan::Result`, `InvalidResponse`).
- Nothing downstream of `CreatePlan` touched.

### Key Discoveries
- Audit: `thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md:124-215` documents the exact shape to replace and the canonical target.
- Schema DSL array-of-object syntax (`references/structured-output.md:25-48`) matches the current `params` nesting verbatim.
- `response.content` is a parsed Hash with consistent string keys (`references/structured-output.md:17-21`) — the `fetch_any` symbol/string quirk disappears.
- Existing JSON fixtures already match `response.content`'s string-keyed shape, so they work unchanged.

## What We're NOT Doing

- Not changing `InvalidResponse` semantics, messages, or the 4 validation guards (missing description, empty revisions, missing summary, missing prompt).
- Not rewording `create_plan_system.md` beyond removing the two `emit_plan` mentions.
- Not touching `MODEL`, `SYSTEM_PROMPT` loading, the `CreatePlan` facade, or `StartGeneration`.
- Not tackling audit Findings 1, 3, 4, 5, 6, 7.
- Not altering the `CreatePlan::AdHocLLM.call` signature or return type.
- Not removing the `invoke_llm` seam — it's orthogonal to canonicality; tests depend on it; keeping it minimizes churn.

## Implementation Approach

Single phase, single commit. The refactor is atomic — any split leaves an intermediate state with dead code (an unused `PlanSchema`, or a half-migrated test).

## Phase 1: Swap `EmitPlan` tool for `PlanSchema` + `with_schema`

### Commit
`phase 2 step 4 refinement: PlanSchema + with_schema (drops emit_plan tool)`

### Overview
Introduce `PlanSchema`, route `AdHocLLM` through `chat.with_schema(...)`, strip the tool plumbing, retarget tests to the new seam.

### Changes Required:

#### 1. New schema class
**File**: `app/schemas/plan_schema.rb` (new)
**Changes**: Mirror the current `params` DSL on `EmitPlan` 1:1 — same field names, same descriptions, same nesting.

```ruby
class PlanSchema < RubyLLM::Schema
  string :instruction_description,
         description: "One-sentence human description of the whole plan."

  array :revisions,
        description: "Ordered list of 3 to 6 atomic revisions." do
    object do
      string :summary, description: "Git-commit-style one-liner summarising this revision."
      string :prompt,  description: "Concrete, file-level instruction passed to the implementer agent."
    end
  end
end
```

#### 2. Rewrite `AdHocLLM` internals
**File**: `app/services/create_plan/ad_hoc_llm.rb`
**Changes**: Delete `EmitPlan` class and `fetch_any`. `invoke_llm` now returns `response.content` (a Hash). `build_result` consumes string keys throughout. Public `.call` signature and behavior unchanged.

```ruby
module CreatePlan
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/create_plan_system.md").read.freeze
    MODEL = "anthropic/claude-haiku-4.5"

    class InvalidResponse < StandardError; end

    def self.call(intent:, clarifications:, context:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      content = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt)
      build_result(content)
    end

    def self.invoke_llm(system:, user:)
      chat = RubyLLM.chat(model: MODEL)
      chat.with_instructions(system)
      chat.with_schema(PlanSchema).ask(user).content
    end

    def self.build_user_prompt(intent, clarifications, _context)
      lines = ["Intent: #{intent}"]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      lines.join("\n")
    end

    def self.build_result(content)
      raise InvalidResponse, "LLM returned no content" if content.nil?

      revisions = Array(content["revisions"]).map do |r|
        { summary: r.fetch("summary"), prompt: r.fetch("prompt") }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?

      CreatePlan::Result.new(
        instruction_description: content.fetch("instruction_description"),
        revisions: revisions
      )
    rescue KeyError => e
      raise InvalidResponse, "plan missing field: #{e.message}"
    end
  end
end
```

#### 3. Update system prompt
**File**: `app/prompts/create_plan_system.md`
**Changes**: Strip the two `emit_plan` tool references. Everything else (the 6 content rules) stays verbatim.

- Line 1, replace: `...emit a short implementation plan by calling the \`emit_plan\` tool.` → `...emit a short implementation plan matching the required JSON schema.`
- Line 12, replace: `Call \`emit_plan\` exactly once with the complete plan. Do not respond with prose.` → `Emit the complete plan in the required JSON shape. Do not respond with prose.`

#### 4. Retarget the test
**File**: `test/services/create_plan/ad_hoc_llm_test.rb`
**Changes**: The stub helper returns a Hash (what `response.content` would be) instead of a pre-called tool. Helper renamed for clarity. All 9 test cases stay; the "never calls emit_plan" case is renamed and its stub returns `nil`.

New helper shape:
```ruby
def with_llm_response(content)
  captured = {}
  original = CreatePlan::AdHocLLM.method(:invoke_llm)

  CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm) do |system:, user:|
    captured[:system] = system
    captured[:user] = user
    content
  end

  yield captured
ensure
  CreatePlan::AdHocLLM.define_singleton_method(:invoke_llm, original) if original
end

def plan_fixture(name)
  JSON.parse(file_fixture("create_plan/#{name}").read)
end
```

Call-site mechanical rewrite across all 9 tests:
- `with_tool_invocation(plan_fixture_args("valid_plan.json"))` → `with_llm_response(plan_fixture("valid_plan.json"))`
- `with_tool_invocation(nil)` → `with_llm_response(nil)`; test renamed from `"raises InvalidResponse when LLM never calls emit_plan"` to `"raises InvalidResponse when LLM returns no content"`.
- The "propagates errors from the LLM" test is already stub-based on `invoke_llm` directly — no change needed.

Fixtures (`test/fixtures/files/create_plan/*.json`) unchanged.

### Success Criteria:

#### Automated Verification:
- [x] All tests pass: `bin/rails test` (79 runs, 264 assertions, 0 failures)
- [x] Target test file passes in isolation: `bin/rails test test/services/create_plan/ad_hoc_llm_test.rb` (9 runs, 23 assertions, 0 failures)
- [x] Linter: no new offenses introduced by this change (baseline repo has 40 pre-existing offenses unrelated to this refactor)
- [x] No stale references remain: grep for `EmitPlan|fetch_any|emit_plan` in `app/` and `test/` returns no matches
- [x] `app/schemas/plan_schema.rb` exists and defines `PlanSchema < RubyLLM::Schema`

#### Manual Verification:
- [x] Send a real build-intent message via the chat UI that triggers `StartGeneration`; an `Instruction` with 3-6 `Revisions` is created, same shape as pre-refactor behavior. (Verified 2026-04-19: "todo list with Tailwind" → 5 revisions + suggest_prompts pills.)
- [x] Rails logs show a single `chat/completions` upstream request per `CreatePlan.call` (no tool-result roundtrip). (Inferred: `AdHocLLM` uses a non-persisted `RubyLLM.chat`, so no DB trace; structurally impossible to roundtrip without `with_tool(..., choice: :required)` + `halt`, both removed.)

**Implementation Note**: After automated verification passes, pause for the manual UI smoke check before marking the phase complete.

## Testing Strategy

### Unit Tests
Existing 9 tests in `test/services/create_plan/ad_hoc_llm_test.rb` re-exercised against the new shape, covering: happy path, system/user prompt assembly, clarifications formatting, nil content, empty revisions, missing description, missing summary, missing prompt, error propagation.

### Manual Testing Steps
1. `bin/rails server`, open a project chat, type a build intent (e.g., "todo list with Tailwind").
2. Wait for the assistant's `start_generation` tool call to resolve.
3. Check `Instruction.last` and `Instruction.last.revisions` in `bin/rails console` — 3-6 revisions with non-empty `summary` and `prompt` fields.

## References
- Audit: `thoughts/shared/research/2026-04-19/ruby-llm-canonical-audit.md:124-215` (Finding 2)
- Skill: `references/structured-output.md:1-50, 152-159`
- Skill: `references/rails.md:35` (`ruby_llm:schema NAME` generator, if ever scaffolded by hand)
- Current code: `app/services/create_plan/ad_hoc_llm.rb:1-78`
- Downstream caller: `app/tools/start_generation.rb:58`
- Tests: `test/services/create_plan/ad_hoc_llm_test.rb:1-112`
- Fixtures: `test/fixtures/files/create_plan/*.json`
