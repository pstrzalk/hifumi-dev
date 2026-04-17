# Preview Isolation — analysis with Kamal

How to safely run previews of generated Rails applications.

## Problem

The generated code is untrusted — the LLM may generate anything. `rails server` on a shared machine gives full access to filesystem, network, env vars. We need isolation.

## Kamal — what it gives, what it doesn't

Kamal does two things:
1. **Deploy pipeline** — build image → push registry → pull → run → health check → switch traffic
2. **kamal-proxy** — reverse proxy with hostname routing (standalone Go binary)

### What Kamal gives

| Need | Kamal | Comment |
|---|---|---|
| Containers | Docker (via Kamal) | Filesystem/process/network isolation |
| Subdomain routing | kamal-proxy | `project-123.preview.domain.com` → container:3000 |
| TLS | kamal-proxy | Let's Encrypt, auto-renewal |
| Health checks | kamal-proxy | Built in |
| Zero-downtime restart | kamal-proxy | Traffic switch after health check |
| Deploying our generator | Kamal (full) | Standard Rails deploy |

### What Kamal does NOT give

| Need | Problem | Solution |
|---|---|---|
| Fast preview start | `kamal deploy` is a full cycle (build → push → pull → run). Too slow for preview after iteration. | Docker directly, kamal-proxy only for routing |
| Dynamic containers | Kamal requires a static `deploy.yml`. Doesn't support "create container on demand". | Docker API + PreviewManager |
| Auto-stop idle | Kamal has no timeouts on containers. | Custom cleanup job |
| Resource limits | Kamal passes Docker options but has no opinionated defaults for isolation. | Explicit Docker flags |
| Network isolation | Kamal does not restrict egress. | Docker `--network internal` + iptables |

### Verdict

**Kamal to deploy our application (the generator). kamal-proxy for preview routing. Docker API for managing preview containers.**

We don't try to fit dynamic previews into the Kamal deploy pipeline.

---

## Architecture: kamal-proxy + Docker

```
Internet
    │
    ▼
┌──────────────────────────────────────────┐
│  kamal-proxy (host, port 443)            │
│  Routing:                                │
│    app.domain.com → generator:3000       │
│    *.preview.domain.com → containers     │
├──────────────────────────────────────────┤
│                                          │
│  ┌────────────────┐  ┌────────────────┐  │
│  │ Generator app  │  │ Preview #1     │  │
│  │ (Kamal deploy) │  │ (Docker)       │  │
│  │ port 3000      │  │ port 3001      │  │
│  │ full network   │  │ no egress      │  │
│  └────────────────┘  └────────────────┘  │
│                                          │
│  ┌────────────────┐  ┌────────────────┐  │
│  │ Preview #2     │  │ Preview #3     │  │
│  │ (Docker)       │  │ (Docker)       │  │
│  │ port 3002      │  │ port 3003      │  │
│  │ no egress      │  │ no egress      │  │
│  └────────────────┘  └────────────────┘  │
│                                          │
│  Docker network: preview-internal        │
│  (--internal = no outbound internet)     │
└──────────────────────────────────────────┘
```

---

## kamal-proxy as router (standalone)

kamal-proxy is a separate Go binary with an HTTP API. Kamal invokes it via SSH, but we can invoke it directly.

### Route registration

```bash
# Add preview
kamal-proxy deploy preview-123 \
  --target 172.18.0.5:3000 \
  --host 123.preview.domain.com

# Remove preview
kamal-proxy remove preview-123

# List active
kamal-proxy list
```

### Dynamic — no restart

Routes are added/removed at runtime. Ideal for preview: start container → register route → stop → deregister.

### Wildcard subdomains

DNS: `*.preview.domain.com` → A record to the server.
kamal-proxy: every preview has an explicit `--host` mapping. No need for a wildcard in the proxy — a DNS wildcard is enough.

---

## Docker — isolation for untrusted code

### Security flags

```bash
docker run \
  --name preview-${PROJECT_ID} \
  --memory=512m \
  --memory-swap=512m \
  --cpus=0.5 \
  --pids-limit=100 \
  --cap-drop=ALL \
  --no-new-privileges \
  --security-opt=no-new-privileges \
  --network=preview-internal \
  --read-only \
  --tmpfs /tmp:size=64m \
  --tmpfs /app/tmp:size=64m \
  -v /workspace/db:/app/db \
  preview-${PROJECT_ID}:${GIT_SHA}
```

| Flag | What it does |
|---|---|
| `--memory=512m` | Hard RAM limit. OOM killer after overrun. |
| `--cpus=0.5` | Max half a core. Prevents CPU hogging. |
| `--pids-limit=100` | Prevents fork bombs. |
| `--cap-drop=ALL` | Zero Linux capabilities (no raw sockets, no mount, etc.) |
| `--no-new-privileges` | Cannot escalate privileges. |
| `--network=preview-internal` | Docker `--internal` network = no outbound internet. |
| `--read-only` | Root filesystem read-only. |
| `--tmpfs /tmp` | Writable /tmp in RAM, limited. |

### Network isolation

```bash
# Network without outbound internet
docker network create --internal preview-internal
```

Containers in `preview-internal` see each other but have no outside routing. kamal-proxy on the host forwards inbound HTTP to containers.

Problem: containers can attack other containers on the same network.
Solution: separate network per container (overhead but max isolation) or `--network=none` + iptables rules.

Pragmatic approach at start: `--network=preview-internal` + limit on concurrent previews. Separate networks per container in the future if it becomes a problem.

### SQLite — natural isolation

Generated apps use SQLite (file in the container). There's no shared database server. Each preview has its own isolated database. This eliminates an entire class of multi-tenant DB problems.

---

## PreviewManager — implementation

```ruby
class PreviewManager
  MEMORY_LIMIT = "512m"
  CPU_LIMIT = "0.5"
  PIDS_LIMIT = "100"
  IDLE_TIMEOUT = 30.minutes
  NETWORK = "preview-internal"

  def start(project)
    image = build_image(project)
    container_id = run_container(project, image)
    register_route(project, container_id)
    health_check(project)
    project.update!(preview_url: preview_url(project), preview_container_id: container_id)
  end

  def stop(project)
    system("docker", "stop", project.preview_container_id)
    system("docker", "rm", project.preview_container_id)
    system("kamal-proxy", "remove", "preview-#{project.id}")
    project.update!(preview_url: nil, preview_container_id: nil)
  end

  def restart(project)
    stop(project)
    start(project)
  end

  private

  def build_image(project)
    tag = "preview-#{project.id}:#{project.latest_revision.git_sha}"
    system("docker", "build",
      "-t", tag,
      "-f", standard_dockerfile_path,  # Dockerfile from our repo, not from the generated app
      project.workspace_path)
    tag
  end

  def run_container(project, image)
    `docker run -d \
      --name preview-#{project.id} \
      --memory=#{MEMORY_LIMIT} --memory-swap=#{MEMORY_LIMIT} \
      --cpus=#{CPU_LIMIT} \
      --pids-limit=#{PIDS_LIMIT} \
      --cap-drop=ALL \
      --no-new-privileges \
      --network=#{NETWORK} \
      --read-only \
      --tmpfs /tmp:size=64m \
      --tmpfs /app/tmp:size=64m \
      #{image}`.strip
  end

  def register_route(project, container_id)
    ip = `docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' #{container_id}`.strip
    system("kamal-proxy", "deploy", "preview-#{project.id}",
      "--target", "#{ip}:3000",
      "--host", "#{project.id}.preview.domain.com")
  end

  def preview_url(project)
    "https://#{project.id}.preview.domain.com"
  end

  def standard_dockerfile_path
    Rails.root.join("lib", "preview", "Dockerfile").to_s
  end
end
```

### Standard Dockerfile (ours, not generated)

Critical: **we never use a Dockerfile from the generated app.** We use our standard Dockerfile.

```dockerfile
# lib/preview/Dockerfile
FROM ruby:3.3-slim

RUN apt-get update && apt-get install -y \
  build-essential libsqlite3-dev nodejs npm \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4
COPY . .
RUN bin/rails db:prepare
RUN bin/rails assets:precompile 2>/dev/null || true

EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

### Build time optimization

A full `docker build` with `bundle install` = 1-3 minutes. Too slow for restart after iteration.

**Base image with pre-installed gems:**

```dockerfile
# Built once, updated rarely
FROM ruby:3.3-slim AS base
RUN apt-get update && apt-get install -y build-essential libsqlite3-dev nodejs npm
RUN gem install bundler

# Pre-install common gems (Devise, Pagy, Tailwind, etc.)
COPY common_gemfile /tmp/Gemfile
RUN cd /tmp && bundle install --jobs 4

# ---
# Per-project image (fast, because most gems are already there)
FROM preview-base:latest
WORKDIR /app
COPY . .
RUN bundle install --jobs 4    # only new gems
RUN bin/rails db:prepare
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

With the base image: per-project build = **10-30 seconds** (only new gems + assets).

### Cleanup idle containers

```ruby
# Solid Queue recurring job
class CleanupIdlePreviewsJob < ApplicationJob
  def perform
    Project.where("preview_started_at < ?", PreviewManager::IDLE_TIMEOUT.ago)
           .where.not(preview_container_id: nil)
           .find_each { |project| PreviewManager.new.stop(project) }
  end
end
```

---

## What we solve, what we don't

### Solved

- **Filesystem isolation** — container does not see the host
- **Process isolation** — pids-limit, cap-drop
- **Network isolation** — --internal network, no egress
- **Resource limits** — memory, CPU, pids
- **Routing** — kamal-proxy, subdomains
- **Database isolation** — SQLite per container
- **Privilege escalation** — no-new-privileges, cap-drop=ALL

### Not solved (acceptable risks to start)

- **Container-to-container** — containers on the same network can see each other. Mitigation: separate networks per container in the future.
- **Docker escape** — Docker isn't a VM. The kernel is shared. Mitigation: this risk is at the Linux level, not our application's. Firecracker/gVisor if deeper isolation is needed.
- **Denial of service** — memory/CPU limited per container, but many containers = many resources. Mitigation: limit on active previews (e.g. 10 per server).
- **Cold start** — first build 1-3 min. Mitigation: base image with pre-installed gems, then 10-30s.

---

## Rollout phases

### PoC (now)
- `docker run` with security flags, without kamal-proxy
- `localhost:{port}` per preview
- Manual cleanup

### MVP (first users)
- kamal-proxy on the server
- Docker `--internal` network
- PreviewManager with Solid Queue
- Auto-cleanup idle
- Base image with common gems
- Limit: 10 active previews

### Production (scale)
- Separate network per container
- Monitoring (memory, CPU, container count)
- Multiple servers with load balancing
- gVisor/Firecracker optional

---

## Impact on existing docs

When Phase 3 is activated (implementation starts) update:

- `../01-vision/02-user-journey.md` Step 5 (Preview) — update to containers instead of raw `rails server`
- `../02-architecture/01-workflows-and-decisions.md` W3 — add Docker build step
- `../02-architecture/03-tech-stack.md` — add Docker/kamal-proxy to the generator stack
- `../../CLAUDE.md` — change Phase 3 status from "analysis" to "active" and add this file to the reading order
