---
date: 2026-05-11
author: Paweł Strzałkowski
branch: main
status: ready
research: thoughts/shared/research/2026-05-11/update-docs-prompt-too-long-instruction-13.md
topic: "Cap W2.6 update_docs diff_stat + expand skeleton .gitignore to prevent vendor/bundle commits"
---

# Implementation Plan: cap W2.6 `update_docs` prompt and harden skeleton `.gitignore`

## Overview

Two-layer fix for the W2.6 `update_docs` "Prompt is too long" failure that ended Instruction 13 (hifumi.dev project 20, Revision 41) on 2026-05-11. Layer 1: expand the skeleton `.gitignore` so future generated apps don't commit `vendor/bundle/` (and adjacent tooling trees) in the first place — the root upstream of the 538KB `git show --stat HEAD` that overflowed Haiku's context window. Layer 2: cap the unbounded `diff_stat` interpolation in `agent(:update_docs)` so the prompt stays bounded regardless of how big the underlying commit is.

## Current State Analysis

The failure is fully documented in [`thoughts/shared/research/2026-05-11/update-docs-prompt-too-long-instruction-13.md`](../../research/2026-05-11/update-docs-prompt-too-long-instruction-13.md). Key facts driving the plan:

- **Crash site**: `lib/roast/revision_workflow.rb:289,301` — `diff_stat = \`git show --stat HEAD\`` is interpolated unbounded into the `update_docs` prompt. `diff_body` (line 290) already has a 16,000-char cap (line 293); only `diff_stat` is missing one.
- **Failure-run numbers**: W2.5 commit `5bc7041` had 8,617 files / 1,744,492 insertions. `git show --stat HEAD` alone was 538,153 chars / 8,624 lines. Prompt overflow → `invalid_request: Prompt is too long`.
- **Root upstream of the bloat**: `vendor/bundle/` (339MB / 8,601 files) got committed by W2.5 because:
  - Skeleton `.gitignore` (`lib/preview/skeleton/.gitignore`) excludes `/.bundle` (the local config dir) but **not** `vendor/bundle/` (the gem install dir).
  - The `claude` agent at W2.3 wrote `BUNDLE_PATH: "vendor/bundle"` into `.bundle/config` and ran `bundle install`, materializing 339MB in the workspace.
  - W2.5 (`lib/roast/revision_workflow.rb:276-280`) runs `git add -A` with no path filter.
- **Test pattern** (matched by this plan): extracted helpers live at `lib/roast/<thing>.rb` with a top-level module name (`AutoRemediate`, `VerifyRevision`) and unit tests at `test/lib/<thing>_test.rb` — see [`lib/roast/auto_remediate.rb`](../../../../lib/roast/auto_remediate.rb) + [`test/lib/auto_remediate_test.rb`](../../../../test/lib/auto_remediate_test.rb).

### Key Discoveries

- `lib/roast/revision_workflow.rb:288-325` — full `agent(:update_docs)` block including the prompt heredoc.
- `lib/roast/revision_workflow.rb:293` — existing 16k char cap on `diff_body`; only this slot is bounded today.
- `lib/preview/skeleton/.gitignore:1-32` — current 32 lines, propshaft + importmap + tailwindcss-rails baseline.
- `lib/preview/skeleton/Gemfile` — confirms `propshaft`, `importmap-rails`, `tailwindcss-rails` (no jsbundling, no webpacker, no node_modules in baseline).
- `lib/roast/revision_workflow.rb:18-21` — uses `require_relative` for sibling helpers; new `StatCap` should follow.

## Desired End State

- `diff_stat` in the `update_docs` prompt is line-capped (default 60-line threshold, 50-line head retained), and the trailing `"N files changed, M insertions(+), K deletions(-)"` summary line is **always preserved** so the model sees the true scale even when truncated.
- Skeleton `.gitignore` excludes `/vendor/bundle/`, `/node_modules/`, `/.yarn/cache/`, `/.yarn/install-state.gz`, and `/app/assets/builds/*` (with `!/app/assets/builds/.keep` to preserve the directory marker, matching the existing `log/` / `tmp/` / `storage/` convention), with a one-paragraph comment header explaining why these matter to the generator pipeline.
- Both fixes are covered by unit tests; no integration test added.

Verifiable via:
- `bin/rails test test/lib/stat_cap_test.rb` (new) green.
- `bin/rails test test/lib/preview/skeleton_gitignore_test.rb` (new) green.
- Full suite (`bin/rails test`) green.

## What We're NOT Doing

Explicit out-of-scope items, per the scoping decisions taken during planning:

- Not pinning `.bundle/config` (e.g., `BUNDLE_PATH` to system GEM_HOME). The gitignore catches the gitignore-relevant outcome; pinning the config doesn't survive an agent that rewrites it anyway.
- Not adding a defensive stage-size guard at W2.5 (no `git diff --cached --numstat` check before commit).
- Not changing W2.F's reset behavior on `ClaudeFailedError`-style raises (Open Question #2 in the research — workspace stays in post-W2.5 state today; out of scope).
- Not cleaning up project 20's prod workspace (339MB `vendor/bundle/` + bad commit `5bc7041` remain on the prod host — handle ad-hoc via `kamal app exec` if/when the project resumes).
- Not changing `diff_body`'s 16k char cap (working as designed; not the cause of this failure).
- Not touching `update_docs`'s allowlist, `--tools Edit,Read` flag, or model selection (`DOCS_MODEL`).

## Implementation Approach

Two atomic commits, ordered to read naturally:

1. **Phase 1 = skeleton `.gitignore` expansion.** Root-cause prevention for all future projects. Self-contained; ships value alone.
2. **Phase 2 = `diff_stat` cap.** Defense-in-depth at the crash site. Catches the next variant where some other tool writes a tree the gitignore doesn't anticipate.

Either order works; Phase 1 first because the .gitignore commit explains the *why* of the bug, and Phase 2 reads as the defense for the next variant.

---

## Phase 1: Expand skeleton `.gitignore` with defensive ignores

### Commit

`skeleton: ignore vendor/bundle and adjacent tooling trees`

### Overview

Append five defensive ignore entries plus a brief rationale comment to the skeleton `.gitignore`. `vendor/bundle/` is the immediate fix for this incident. `node_modules/`, `/.yarn/cache/`, `/.yarn/install-state.gz` cover the JS toolchain trees an agent could create if it pulls in `jsbundling-rails` / `cssbundling-rails` / `shakapacker` via a Gemfile edit. `app/assets/builds/*` covers `tailwindcss-rails`'s build output (which can sneak into commits when the agent runs the dev server during a revision).

### Changes Required

#### 1. Skeleton `.gitignore`

**File**: `lib/preview/skeleton/.gitignore`
**Changes**: append a new section after the existing entries. Use a comment header explaining the rationale so a future maintainer (human or agent) doesn't strip these as "redundant with Rails defaults."

```
# Ignore installed dependency trees. The generator runs `git add -A` at W2.5
# with no path filter; any tree under these paths would otherwise enter the
# commit diff and bloat the W2.6 update_docs prompt
# (see thoughts/shared/research/2026-05-11/update-docs-prompt-too-long-instruction-13.md).
/vendor/bundle/
/node_modules/
/.yarn/cache/
/.yarn/install-state.gz
/app/assets/builds/*
!/app/assets/builds/.keep
```

The `!/app/assets/builds/.keep` negation matches the existing skeleton convention for `log/`, `tmp/`, and `storage/` (which all keep `.keep` tracked so the directory survives a fresh `git clone`). The skeleton currently tracks `app/assets/builds/.keep` and `app/assets/builds/tailwind.css`; without the negation, the workspace baseline commit would also stop tracking `.keep`, making the directory disappear on clone. The preview `Dockerfile` regenerates `tailwind.css` via `RUN bin/rails tailwindcss:build`, so the build artifact itself doesn't need to be tracked, but the directory marker does.

#### 2. Unit test for the skeleton `.gitignore` contents

**File**: `test/lib/preview/skeleton_gitignore_test.rb` (new)
**Changes**: one assertion per ignored entry. Each entry is one logical regression branch.

```ruby
require "test_helper"

class Preview::SkeletonGitignoreTest < ActiveSupport::TestCase
  SKELETON_GITIGNORE = Rails.root.join("lib/preview/skeleton/.gitignore")

  setup do
    @contents = SKELETON_GITIGNORE.read
  end

  test "ignores /vendor/bundle/ (incident fix: hifumi.dev 2026-05-11)" do
    assert_match(%r{^/vendor/bundle/$}, @contents)
  end

  test "ignores /node_modules/" do
    assert_match(%r{^/node_modules/$}, @contents)
  end

  test "ignores /.yarn/cache/" do
    assert_match(%r{^/\.yarn/cache/$}, @contents)
  end

  test "ignores /.yarn/install-state.gz" do
    assert_match(%r{^/\.yarn/install-state\.gz$}, @contents)
  end

  test "ignores /app/assets/builds/*" do
    assert_match(%r{^/app/assets/builds/\*$}, @contents)
  end

  test "preserves /app/assets/builds/.keep so the directory survives a fresh clone" do
    assert_match(%r{^!/app/assets/builds/\.keep$}, @contents)
  end
end
```

### Success Criteria

#### Automated Verification:
- [x] New test file is green: `bin/rails test test/lib/preview/skeleton_gitignore_test.rb`
- [x] Full suite stays green: `bin/rails test` (one pre-existing failure unrelated to this plan: `ProjectsControllerTest#test_GET_/projects/new_(signed_in)_renders_new_with_placeholder_text` — placeholder text changed in recent UI redesign, test not updated; failure reproduces on plain `main` before any of this plan's changes are applied)
- [x] Linting passes: `bundle exec rubocop` (clean on new test file)

#### Manual Verification:
- [x] Init a fresh workspace by copying the skeleton (e.g., `cp -r lib/preview/skeleton /tmp/sk-test && cd /tmp/sk-test && git init && git add -A && git commit -m baseline`). Then simulate the failure scenario: `bundle config set --local path vendor/bundle && bundle install --jobs 4` (this will materialize ~339MB under `vendor/bundle/`). Run `git status` — expect `vendor/bundle/` to **not** appear as untracked (it's ignored). Run `git add -A && git status --short` — staged set should be empty (no `vendor/bundle/*` entries). _Verified with synthesized `vendor/bundle/ruby/4.0.0/gems/somegem-1.0.0/{lib/somegem.rb,somegem.gemspec}` files instead of a real `bundle install` to keep it fast — same ignore rule applies; `git status --short` and `git add -A && git status --short` both empty._
- [x] Repeat for `mkdir -p node_modules && touch node_modules/sentinel` — confirm `git status` ignores it. Also verified `.yarn/cache/foo.zip` and `.yarn/install-state.gz` ignored.
- [x] For `app/assets/builds/`: the skeleton already tracks `tailwind.css` and `.keep`, so `touch`-ing those would only show as `modified:`, not test the ignore rule. Use a **new** filename: `touch app/assets/builds/new-artifact.css && git status` — confirm the new file is ignored. Then `git ls-files app/assets/builds/` should still show `.keep` (preserved by the `!/app/assets/builds/.keep` negation), confirming the directory marker survives. _Verified: `git status --short` empty after `touch app/assets/builds/new-artifact.css`; `git ls-files app/assets/builds/` returned `app/assets/builds/.keep`._

**Implementation Note**: After Phase 1's automated checks pass, pause for manual confirmation from the human that the skeleton fix behaves correctly in a hand-init'd workspace before moving to Phase 2.

---

## Phase 2: Cap `diff_stat` in W2.6 `update_docs` prompt

### Commit

`roast: cap update_docs diff_stat by lines, preserve summary`

### Overview

Extract the diff-stat truncation into a small module `StatCap` (following the existing `AutoRemediate` / `VerifyRevision` pattern) and apply it to `diff_stat` before interpolation into the `update_docs` prompt. The cap is line-based (60-line threshold by default; first 50 lines retained), and the trailing summary line is always preserved — so even in a pathological revision the model sees `"N files changed, M insertions(+)"` and knows the true scale.

### Changes Required

#### 1. New module: `StatCap`

**File**: `lib/roast/stat_cap.rb` (new)
**Changes**: pure-Ruby module, single public method. No I/O. Matches `AutoRemediate` file-and-naming convention (top-level module, `# frozen_string_literal: true`).

```ruby
# frozen_string_literal: true

# StatCap caps `git show --stat` output by line count while always preserving
# the trailing summary line ("N files changed, M insertions(+), K deletions(-)").
#
# Used by W2.6 update_docs to keep the prompt bounded when a single revision
# touches many files (e.g., an accidentally-committed vendor tree). The
# summary line is the most valuable single signal in a pathological case —
# without it, a model handed a truncated stat would have no idea that the
# revision was outside normal scale.
#
# Context: thoughts/shared/research/2026-05-11/update-docs-prompt-too-long-instruction-13.md
module StatCap
  DEFAULT_LINE_THRESHOLD = 60
  DEFAULT_HEAD_LINES = 50

  def self.call(stat, line_threshold: DEFAULT_LINE_THRESHOLD, head_lines: DEFAULT_HEAD_LINES)
    return stat if stat.nil? || stat.empty?

    lines = stat.lines
    # Two reasons to skip truncation: (1) input already fits the threshold,
    # (2) caller passed head_lines >= line_threshold, in which case truncation
    # would produce a duplicated summary line and a negative omitted count.
    # Trip the same early return — input shorter than head + summary can't
    # meaningfully be truncated anyway.
    return stat if lines.size <= line_threshold
    return stat if lines.size <= head_lines + 1

    summary = lines.last
    head = lines.first(head_lines).join
    omitted = lines.size - head_lines - 1
    "#{head}[... #{omitted} more file(s) truncated ...]\n#{summary}"
  end
end
```

#### 2. Wire `StatCap` into `agent(:update_docs)`

**File**: `lib/roast/revision_workflow.rb`
**Changes**:
- Add `require_relative "stat_cap"` to the top-of-file require block (after `require_relative "workflow_env"` at line 21).
- Modify the `agent(:update_docs)` block at lines 288-294 to pass `diff_stat` through `StatCap.call`. The `diff_body` cap is left untouched.

Before (lines 288-294):
```ruby
agent(:update_docs) do
  diff_stat = `cd #{Shellwords.escape(WORKSPACE)} && git show --stat HEAD`
  diff_body = `cd #{Shellwords.escape(WORKSPACE)} && git show HEAD`
  # Cap the diff body at a generous but bounded size — large changes still
  # get a structural summary via stat, full bodies for small ones.
  diff_body = "#{diff_body[0, 16_000]}\n[... diff truncated at 16k chars ...]" if diff_body.length > 16_000
```

After:
```ruby
agent(:update_docs) do
  diff_stat = `cd #{Shellwords.escape(WORKSPACE)} && git show --stat HEAD`
  diff_stat = StatCap.call(diff_stat)
  diff_body = `cd #{Shellwords.escape(WORKSPACE)} && git show HEAD`
  diff_body = "#{diff_body[0, 16_000]}\n[... diff truncated at 16k chars ...]" if diff_body.length > 16_000
```

(The existing comment at lines 291-292 about "large changes still get a structural summary via stat" remains accurate — now even more so, because `StatCap` guarantees the summary line survives.)

#### 3. Unit tests for `StatCap`

**File**: `test/lib/stat_cap_test.rb` (new)
**Changes**: one test per logical branch.

```ruby
require "test_helper"
require Rails.root.join("lib/roast/stat_cap")

class StatCapTest < ActiveSupport::TestCase
  test "nil stat is returned unchanged" do
    assert_nil StatCap.call(nil)
  end

  test "empty stat is returned unchanged" do
    assert_equal "", StatCap.call("")
  end

  test "stat below threshold is returned unchanged" do
    stat = (1..30).map { |i| " file#{i}.rb | 1 +\n" }.join +
           " 30 files changed, 30 insertions(+)\n"
    assert_equal stat, StatCap.call(stat)
  end

  test "stat exactly at threshold is returned unchanged" do
    lines = (1..59).map { |i| " file#{i}.rb | 1 +\n" }.join
    summary = " 59 files changed, 59 insertions(+)\n"
    stat = lines + summary
    assert_equal 60, stat.lines.size
    assert_equal stat, StatCap.call(stat)
  end

  test "stat just above threshold is truncated, summary preserved" do
    lines = (1..60).map { |i| " file#{i}.rb | 1 +\n" }
    summary = " 60 files changed, 60 insertions(+)\n"
    stat = lines.join + summary

    result = StatCap.call(stat)

    assert_includes result, " file1.rb | 1 +\n"
    assert_includes result, " file50.rb | 1 +\n"
    assert_not_includes result, " file51.rb | 1 +\n"
    assert_includes result, "[... 10 more file(s) truncated ...]"
    assert result.end_with?(summary), "summary line must be preserved at the end"
  end

  test "pathological case (8,624 lines, vendor/bundle scenario)" do
    lines = (1..8623).map { |i| " path/to/file#{i}.rb | 1 +\n" }
    summary = " 8617 files changed, 1744492 insertions(+), 89 deletions(-)\n"
    stat = lines.join + summary

    result = StatCap.call(stat)

    assert_operator result.length, :<, 5_500, "capped output should stay well under 5KB"
    assert_includes result, "[... 8573 more file(s) truncated ...]"
    assert result.end_with?(summary)
    refute_includes result, " path/to/file51.rb | 1 +\n"
  end

  test "stat with no recognizable summary still returns last line as 'summary' (defensive)" do
    stat = (1..70).map { |i| "weird-line-#{i}\n" }.join

    result = StatCap.call(stat)

    assert_includes result, "weird-line-1\n"
    assert_includes result, "[... 19 more file(s) truncated ...]"
    assert result.end_with?("weird-line-70\n")
  end

  test "honors custom thresholds" do
    stat = (1..20).map { |i| " file#{i}.rb | 1 +\n" }.join +
           " 20 files changed, 20 insertions(+)\n"

    result = StatCap.call(stat, line_threshold: 10, head_lines: 5)

    assert_includes result, " file1.rb | 1 +\n"
    assert_includes result, " file5.rb | 1 +\n"
    refute_includes result, " file6.rb | 1 +\n"
    assert_includes result, "[... 15 more file(s) truncated ...]"
    assert result.end_with?(" 20 files changed, 20 insertions(+)\n")
  end

  test "misordered thresholds (head_lines >= line_threshold) returns input unchanged instead of producing garbage" do
    # Defensive: with head_lines: 50, line_threshold: 10 and 20 lines of input,
    # the naive truncation math would yield omitted = -31 and duplicate the
    # summary line. The guard short-circuits before that.
    stat = (1..20).map { |i| " file#{i}.rb | 1 +\n" }.join

    result = StatCap.call(stat, line_threshold: 10, head_lines: 50)

    assert_equal stat, result
  end
end
```

### Success Criteria

#### Automated Verification:
- [x] StatCap unit tests pass: `bin/rails test test/lib/stat_cap_test.rb` (9 runs, 36 assertions, 0 failures)
- [x] Full suite stays green: `bin/rails test` (373 runs, 1354 assertions, 1 failure — pre-existing on `main`, same `ProjectsControllerTest` placeholder failure as Phase 1; no regressions from this plan)
- [x] Linting passes: `bundle exec rubocop` (new files `lib/roast/stat_cap.rb` + `test/lib/stat_cap_test.rb` clean; `revision_workflow.rb` has 7 pre-existing offenses unchanged by this plan)

#### Manual Verification:
- [x] **Normal-size revision**: run an end-to-end generation (e.g., a small todo-list prompt via `bin/generate full` or the UI). Inspect the W2.6 prompt that goes to the docs agent (either by adding a temporary `puts diff_stat` in dev, or by running the workflow against a workspace and watching the Kamal/dev logs). Confirm the stat appears in full (no truncation marker present). _Verified via `bin/rails runner` instead: built a scratch 5-file commit in `/tmp/statcap-small`, ran `StatCap.call(\`git show --stat HEAD\`)` — input 12 lines, output 12 lines, `stat == capped` true, no truncation marker. Doesn't require a full E2E run._
- [x] **Pathological revision**: in a scratch workspace, create a fake 8,000-file commit (`for i in {1..8000}; do mkdir -p tmp_files/$((i/100)); touch tmp_files/$((i/100))/file$i.rb; done; git add -A; git commit -m bloat`) and run just the `update_docs` step against it (or run `StatCap.call(`git show --stat HEAD`)` from `bin/rails console` in that workspace). Confirm the output is ~5KB, contains the head 50 lines, the truncation marker with an accurate omitted count, and the summary line. _Verified: 8,000-file commit in `/tmp/statcap-test` — raw stat 232,168 bytes / 8,007 lines → capped 1,482 bytes / 52 lines; truncation marker `[... 7956 more file(s) truncated ...]` accurate; summary line ` 8000 files changed, 0 insertions(+), 0 deletions(-)` preserved as last line._
- [ ] **End-to-end smoke**: if budget allows, run `E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb` (the canonical full-chain test from `CLAUDE.md`) and confirm it stays green. _Skipped — explicit "if budget allows" gate; needs operator approval before burning a real ~900s LLM run._

**Implementation Note**: pause for manual confirmation after Phase 2's automated checks before considering the plan complete.

---

## Testing Strategy

### Unit Tests
- **StatCap**: branches above (nil, empty, below-threshold, at-threshold, just-above-threshold, pathological, no-summary, custom thresholds).
- **Skeleton `.gitignore`**: one assertion per ignored entry.

### Integration Tests
None added. The failure is data-driven; the existing E2E test (`E2E_GENERATE=1 bin/rails test test/integration/generate_todo_list_test.rb`) exercises the workflow end-to-end and is sufficient to catch any regression introduced by the prompt-shape change.

### Manual Testing Steps
Listed inline per phase. Most critical: confirm a normal-size revision still gets the full stat (no false truncation), and the pathological case truncates cleanly with the summary preserved.

## Performance Considerations

`StatCap.call` is O(L) where L = stat line count. For the 8,624-line pathological case the call runs in single-digit milliseconds. No perf concern.

## Migration Notes

- **New projects** automatically get the expanded `.gitignore` and the capped `update_docs` prompt.
- **Existing prod workspaces** (e.g., project 20 on hifumi.dev) are not touched. Their `vendor/bundle/` remains tracked in their own git history. If those projects ever resume generation, the W2.6 cap will protect `update_docs`, but the underlying commit bloat persists in their history — that's accepted scope.

## References

- Research: [`thoughts/shared/research/2026-05-11/update-docs-prompt-too-long-instruction-13.md`](../../research/2026-05-11/update-docs-prompt-too-long-instruction-13.md)
- Companion research (model-routing audit): [`thoughts/shared/research/2026-05-11/per-user-model-config-per-stage.md`](../../research/2026-05-11/per-user-model-config-per-stage.md)
- Earlier plan that shipped `--tools Edit,Read` + `ensure_passing`: [`thoughts/shared/plans/2026-05-01/phase-5-step-2-revision-workflow-waste.md`](../2026-05-01/phase-5-step-2-revision-workflow-waste.md)
- W2.6 cost-surface analysis (still relevant; options A–F deferred): [`docs/09-ideas/03-docs-and-knowledge-management.md`](../../../../docs/09-ideas/03-docs-and-knowledge-management.md)
- W2 canonical step definitions: [`docs/02-architecture/01-workflows-and-decisions.md`](../../../../docs/02-architecture/01-workflows-and-decisions.md)
- Crash site: `lib/roast/revision_workflow.rb:288-325`
- Skeleton baseline: `lib/preview/skeleton/.gitignore`
- Extracted-helper pattern reference: `lib/roast/auto_remediate.rb` + `test/lib/auto_remediate_test.rb`
