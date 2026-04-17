# Git Integration — ideas

Git isn't just an internal mechanism (checkpointing, revert). It's an educational and professional tool. Users learn Rails by looking at what the agent did and how.

## Motivation

- **Popularizing Ruby on Rails** — this is the overarching goal. A generated app is a clean Rails repo, not vendor lock-in. The user gets a professional base and continues with standard Rails tools.
- A tool for professionals and future professionals
- Git diff = "what the agent did and why" — the best form of learning
- Export = "now it's your project." Zero dependency on our platform. Standard Rails, standard git, standard tools.
- Clean git history = a professional base, not a generated blob

## Ideas

### Change visibility
- **Git diff between revisions** — in the UI, syntax-highlighted. User clicks a revision → sees what changed. Learns how the agent builds a Rails app.
- **Annotated commits** — every commit has a meaningful message describing WHAT and WHY. Not "update files" but "Add Flower model with name, price, seasonal availability. Belongs_to :category with counter cache."
- **Diff in chat** — after a revision completes, the LLM can show key changes inline, not just "done". Tool `ShowDiff`?
- **File browser** — browse the generated code per revision. Like GitHub code view but in our UI.
- **Blame view** — which instruction/revision added which line. Links code to decisions from the chat.

### Export and continuing work
- **Push to GitHub** — OAuth, new repo, full commit history
- **Push to GitLab / Bitbucket** — analogous
- **Clone instructions** — "here is how to clone and continue locally" (shown after export)
- **Clean Rails repo** — zero dependency on our platform. The generated app is a standard Rails project: `git clone`, `bundle install`, `rails db:prepare`, `rails server`. Works with any editor, CI, hosting. No custom wrappers, no proprietary gems.
- **README.md** — generated automatically: what the app is, how to run it, which gems and why, architectural decisions. Standard onboarding for a new developer.
- **CLAUDE.md** — optionally, for those who want to continue with Claude Code. But it's an add-on, not a requirement.

### Education
- **"Explain this change"** — user clicks on a diff and asks "why this way?" → LLM explains in Rails Way context
- **Step-by-step replay** — playback of the app's construction step by step. Like a timelapse but with explanations. "Here is how this app was built from scratch."
- **Rails conventions highlighting** — in the diff, mark "this is a Rails convention" vs. "this is specific to your app"
- **Compare with alternative** — "what would it look like if we used X instead of Y?" (future, requires branching)

### Professional workflow
- **Branch per feature** — instead of linear history, optionally: every instruction is a branch + merge. More realistic git flow.
- **PR-like review** — before applying a revision the user can do a "review" of changes. Code review as a form of learning.
- **Git hooks in the generated app** — linting (HERB), tests, formatting. Teaches good practices from day one.
- **Conventional commits** — commit format (feat:, fix:, refactor:) for readable history

### Collaboration
- **Invite collaborator** — someone else can join the project and continue in chat
- **Fork project** — copy someone's project and modify (like GitHub fork)
- **Share snapshot** — link to a specific revision to show someone

## Status

Stage: a collection of ideas, to be prioritized on the roadmap.
