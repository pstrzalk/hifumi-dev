# Docs and knowledge management efficiency — ideas

The W2 workflow maintains four files in the *generated* app's `docs/` directory:

- `architecture.md`
- `conventions.md`
- `domain.md`
- `revision_notes.md` (append-only)

Producer: `agent(:update_docs)` (haiku) at W2.6, after every successful
revision commit. Consumer: `ruby(:build_prompt)` at W2.2 of the *next*
revision — the four files are spliced into the codegen agent's prompt as
"Current application state (manifest)" + "Context from previous revisions".
Conceptually they are workflow memory; the user-facing artifact in their
generated repo is a byproduct.

Observed 2026-05-01 during smoke run on a 6-revision blog app
(`tmp/blog_application_run_kamal.log`).

## What's biting us

### 1. Cost ratio inverts on small revisions

| rev | what it did | codegen | update_docs | docs/codegen |
|-----|-------------|---------|-------------|--------------|
| #22 | Post model | ~$0.18 | ~$0.06 | 33% |
| #23 | Comment scaffold | ~$0.51 | ~$0.10 | 19% |
| #24 | one-line `dependent: :destroy` | $0.084 | $0.094 | **112%** |
| #25 | Tailwind styling | $0.147 | $0.121 | 82% |
| #26 | (small) | $0.05 | $0.20 | **400%** |
| #27 | (small) | $0.18 | $0.10 | 56% |

Run total: ~$2.14 across 6 revisions, ~7 minutes wall.

### 2. `revision_notes.md` grows unbounded

Append-only, re-fed in full to *both* `build_prompt` (next revision's
codegen) AND `update_docs` itself. Haiku input on update_docs grew
6.91k → 7.47k tokens between rev #22 and rev #27 in this run alone.
Linear growth in revisions, paid twice per revision.

### 3. Partial overlap with the workspace snapshot

`build_prompt` (`lib/roast/revision_workflow.rb:153-166`) already pre-renders
a deterministic structural snapshot: a sorted index of `app/controllers/`
and `app/models/`, plus the full bodies of `config/routes.rb` and
`app/controllers/application_controller.rb`. That's the deterministic
version of what `architecture.md` tries to describe with an LLM. Both
end up in the same prompt. The snapshot is cheaper, more accurate, and
self-updating; `architecture.md` is partially redundant.

### 4. `update_docs` reads all four files every revision

Even when the diff only warrants touching one of them. Plus an EISDIR
on the `docs/` directory itself before reading the files (fixed in this
session via prompt rewording — see item #1 deferral context).

## Options to consider

### A. Cap `revision_notes.md` feed in `build_prompt` to last N entries

Reduces input growth on codegen. Behavior change: codegen agent loses
visibility into older revision context. Probably fine — older context is
already reflected in the workspace itself.

### B. In `update_docs`, only feed the doc file the agent will plausibly edit

Requires a heuristic (or a deterministic rule) for "which file matches this
diff" before the agent runs. Design work, not a tweak.

### C. Make `revision_notes.md` deterministic

Replace the agent append step with a Ruby step that writes a structured
entry from `revision_summary` + diff stat. Saves ~half of the
`update_docs` work and bounds growth via a deterministic format. But it
loses the LLM's interpretive layer ("WHY this decision was made") that
the current prompt asks for.

### D. Drop `architecture.md` from `build_prompt`

Overlaps with the workspace snapshot. Smallest of the structural changes
but still a behavior change — the snapshot doesn't include
*relationships* (has_many, belongs_to), which `architecture.md` does.

### E. Drop the docs system entirely from the workflow

Replace with: (a) the workspace snapshot (already deterministic), (b)
`git log --oneline -20` for prior-revision context. Loses: domain
glossary, conventions.md, the user-facing docs in the generated repo.

### F. Separate user-artifact from workflow-memory

User-facing docs = generated once at the end of a session (or on-demand),
not after every revision. Workflow memory = small, deterministic, capped,
internal (e.g. a sidecar JSON in the project record, out of the agent's
reach).

## Trigger to revisit

The current decision is to **wait for more sample apps** before redesigning.
This single 6-revision run is not a representative sample. Revisit once we
have 5-10 sample apps of varying complexity (simple CRUD, multi-model with
relationships, auth, file upload, jobs, etc.) and can see the cost +
quality tradeoff across the whole space.

Specifically interested in:

- Does the codegen agent visibly *use* the contents of `domain.md` and
  `conventions.md`? (The case for keeping LLM-written docs hangs on this.)
- How does `revision_notes.md` grow on a 20-revision app? 50?
- Are users actually reading the generated `docs/` files in their repos?
  (Determines whether B/C/E that drop the user-facing artifact are
  acceptable.)

## Open questions

1. Is the user-facing `docs/` artifact valuable, or purely an internal
   mechanism that leaks into the user's repo?
2. What's the value of `domain.md` and `conventions.md` specifically —
   does the codegen agent's behavior visibly degrade without them?
3. If docs are internal-only, would moving workflow memory off the
   workspace filesystem (out of agent reach) simplify and harden the
   pipeline?
