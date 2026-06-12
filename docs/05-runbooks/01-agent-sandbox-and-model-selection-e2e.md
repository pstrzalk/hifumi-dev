# E2E verification — per-project model selection + agent sandbox

How to verify, end to end, that (a) a project's per-stage model selection drives real generation, and (b) the codegen agent runs in a per-instruction isolated container. Three levels of increasing fidelity, then the production check via `kamal app exec`.

## Prerequisites
- Dev server + Solid Queue worker running (`bin/dev`), or use the synchronous `bin/generate` CLI (no worker needed).
- A signed-in user with a real **OpenRouter API key** (Account → Integrations). Generation reads `project.user.profile.openrouter_api_key`.
- For Level 3 / sandbox: Docker available; the generator image built (`docker build -t hifumi-dev:local .`).

## Level 1 — model selection UI + persistence (no Docker, no LLM spend)
1. Account → Integrations → **default ai models**: change a stage (e.g. "Code generation" → Claude Opus 4.6), save, reload — it persists.
2. New-project page → expand **ai models**: every stage selector renders, pre-filled from your defaults. Submit.
3. Project → Build tab → expand **ai models**: change a stage, save → "Saved." appears.
4. Snapshot semantics — a default change must not mutate existing projects:
   ```bash
   bin/rails runner 'p p.slice(:chat_model,:code_model,:docs_model) if (p = Project.last)'
   ```

## Level 2 — selection drives real generation (OpenRouter, no Docker)
Forces the OpenRouter path so the full model id flows (dev's default claudesubscription ignores selection by design).

```bash
# 1) prep a keyed, initialized project with a distinctive model + a real revision
bin/rails runner '
  user = User.find_by(email: "you@example.com")
  p = user.projects.detect { |pr| File.exist?(File.join(pr.workspace_path, "Gemfile")) } || user.projects.last
  p.create_chat! unless p.chat
  p.update!(code_model: "anthropic/claude-opus-4.6", docs_model: "anthropic/claude-haiku-4.5")
  i = p.instructions.create!(user_intent: "add a Todo model", description: "todo",
        phase: :implementing,
        anchor_message: p.chat.messages.create!(role: :user, content: "add todos"))
  i.revisions.create!(project: p, position: 0, status: :pending,
        summary: "Add Todo model",
        prompt: "Create a Todo model with title:string and done:boolean, a migration, and a model test.")
  puts "PROJECT=#{p.id} INSTRUCTION=#{i.id}"
'
# 2) run it on the OpenRouter path
FORCE_OPENROUTER=1 bin/generate execute --instruction-id <INSTRUCTION>
```
Note the colon spacing: `phase: :implementing` (a space after `phase:`), not `phase::implementing` (that parses as a constant). The instruction needs at least one revision or there is nothing to execute.

**Pass:** `log/development.log` shows `[W2.1] Model: anthropic/claude-opus-4.6` (your selection, not `sonnet`), and the workspace gets an `Add Todo model` commit with `app/models/todo.rb` + migration + test.

## Level 3 — sandbox isolation (Docker)
The isolation does not depend on a full generation — probe it directly with the real `Roast::Sandbox` argv.

**C1 — mount scoping / sibling denial / no socket** (no tokens). Mount one real workspace, try to reach a sibling:
```bash
bin/rails runner '
  require Rails.root.join("lib/roast/sandbox").to_s
  root = Project.workspace_root
  dirs = Dir.children(root).select { |d| d.start_with?("project_") }.sort
  mounted, sibling = File.join(root, dirs[0]), File.join(root, dirs[1])
  probe = "ls #{root}; (ls #{sibling} && echo LEAK) || echo DENIED-sibling; (ls /var/run/docker.sock && echo LEAK) || echo DENIED-socket"
  argv = Roast::Sandbox.wrap(image: "hifumi-dev:local", command: ["sh","-lc",probe],
           env_keys: [], workspace: mounted, name: "isolation-probe")
  system(*argv)
'
```
**Pass:** `ls <root>` shows only the one mounted project; the sibling → `No such file or directory` (DENIED); `/var/run/docker.sock` → DENIED.

**C2 — the agent starts in the locked-down, non-root container** (the question a Mac can't answer about prod). The sandbox runs everything as `generator` with zero capabilities (issue #24); probe with the same flags `Roast::Sandbox` emits:
```bash
ws="$(bin/rails runner 'print File.join(Project.workspace_root, Dir.children(Project.workspace_root).grep(/^project_/).sort.first)')"
docker run --rm --user generator --cap-drop=ALL --security-opt=no-new-privileges \
  --entrypoint /bin/sh -v "$ws:$ws" hifumi-dev:local -lc \
  'id; echo "HOME=$HOME"; /usr/local/bin/claude --version; touch /usr/local/bundle/.probe && echo bundle-writable && rm /usr/local/bundle/.probe'
```
**Pass:** `uid=1000(generator)`, `HOME=/home/generator`, a `claude` version print, and `bundle-writable` — the agent starts and bundler can install gems inside the locked-down container.

**Full sandboxed generation (optional):** `HIFUMI_AGENT_IMAGE=hifumi-dev:local FORCE_AGENT_SANDBOX=1 bin/generate execute --instruction-id <N>`, and while it runs, `docker ps --filter name=agent-revision` + `docker inspect`. On a Mac this exercises a Linux container over a macOS-bundled workspace (platform mismatch on gem reconciliation) — prefer the real Linux host for this one.

## Production verification — `kamal app exec`
On the deployed host, run the same checks via the **running** app container (it carries the Docker socket + the workspace volume; a fresh `kamal app exec` container may not — so use `--reuse`):

```bash
# model wiring (read-only, no tokens)
kamal app exec --reuse "bin/rails runner 'puts ExecuteInstructionJob.new.send(:roast_model_env, Project.find(<id>)).inspect'"

# model wiring + isolation probe in one shot (read-only; uses the deployed HIFUMI_AGENT_IMAGE)
# bin/verify-agent-sandbox prints the per-project model env, then launches one throwaway
# container with the real Roast::Sandbox argv and checks uid/claude + sibling + socket.
kamal app exec --reuse "bin/verify-agent-sandbox <project-id>"

# full sandboxed generation (burns the owner's tokens; runs on prod — do deliberately)
kamal app exec --reuse "bin/generate execute --instruction-id <N>"
```
The host probes touch real tenant workspace paths — keep them **read-only** (`ls`/`cat`). C1/C2 cost nothing; only the full generation burns tokens. These also confirm `HIFUMI_AGENT_IMAGE` points at the running release.

## Recorded baseline (2026-06-12, dev box + production host)
- **Model wiring (dev + prod):** `roast_model_env` → `HIFUMI_DEV_MODEL=anthropic/claude-opus-4.6`, `HIFUMI_DEV_DOCS_MODEL=anthropic/claude-haiku-4.5`; off-list models rejected. Prod (project 22): `use_openrouter?=true sandboxed?=true`, both keys forwarded.
- **Real generation, unsandboxed (dev, opus):** instruction completed, exit 0, ~39s; `app/models/todo.rb` + migration + test committed; `[W2.1] Model: anthropic/claude-opus-4.6` confirmed.
- **C1 (dev + prod):** mounted workspace only; sibling `project_*` → `No such file or directory`; no `/var/run/docker.sock`. Prod via `kamal app exec --reuse "bin/verify-agent-sandbox 22"`: ws-root listed only `project_22`, sibling denied, socket denied, `claude 2.1.126` started, image = `localhost:5555/hifumi-dev:latest`.
- **Full sandboxed generation (prod, 2026-06-12, pre-fix):** FAILED — verify hit `SQLite3::ReadOnlyException` (capless root vs uid-1000 files, issue #24); led to the uniform-uid sandbox (`--user generator`, zero cap-adds, pre-run workspace re-relax).
- Still to confirm on the Linux host: a full sandboxed generation green under the uniform-uid sandbox (rerun after deploying the issue-#24 fix).
