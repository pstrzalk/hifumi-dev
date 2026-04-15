# Preview Isolation — analiza z Kamal

Jak bezpiecznie uruchamiać preview wygenerowanych aplikacji Rails.

## Problem

Wygenerowany kod jest untrusted — LLM może wygenerować cokolwiek. `rails server` na wspólnej maszynie daje pełny dostęp do filesystem, sieci, env vars. Potrzebujemy izolacji.

## Kamal — co daje, czego nie daje

Kamal robi dwie rzeczy:
1. **Deploy pipeline** — build image → push registry → pull → run → health check → switch traffic
2. **kamal-proxy** — reverse proxy z hostname routing (standalone Go binary)

### Co Kamal daje

| Potrzeba | Kamal | Komentarz |
|---|---|---|
| Kontenery | Docker (przez Kamal) | Izolacja filesystem/process/network |
| Routing subdomen | kamal-proxy | `project-123.preview.domain.com` → kontener:3000 |
| TLS | kamal-proxy | Let's Encrypt, auto-renewal |
| Health checks | kamal-proxy | Wbudowane |
| Zero-downtime restart | kamal-proxy | Traffic switch po health check |
| Deploy naszego generatora | Kamal (full) | Standardowy Rails deploy |

### Czego Kamal NIE daje

| Potrzeba | Problem | Rozwiązanie |
|---|---|---|
| Szybki start preview | `kamal deploy` to pełny cykl (build → push → pull → run). Za wolne na preview po iteracji. | Docker bezpośrednio, kamal-proxy tylko do routingu |
| Dynamiczne kontenery | Kamal wymaga statycznego `deploy.yml`. Nie obsługuje "stwórz kontener na żądanie". | Docker API + PreviewManager |
| Auto-stop idle | Kamal nie ma timeoutów na kontenery. | Custom cleanup job |
| Resource limits | Kamal przekazuje Docker options, ale nie ma opiniated defaults dla izolacji. | Explicit Docker flags |
| Network isolation | Kamal nie ogranicza egress. | Docker `--network internal` + iptables |

### Verdict

**Kamal do deployu naszej aplikacji (generatora). kamal-proxy do routingu preview. Docker API do zarządzania kontenerami preview.**

Nie próbujemy wcisnąć dynamicznych preview w Kamal deploy pipeline.

---

## Architektura: kamal-proxy + Docker

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

## kamal-proxy jako router (standalone)

kamal-proxy to osobny Go binary z HTTP API. Kamal wywołuje go przez SSH, ale możemy wywoływać go bezpośrednio.

### Rejestracja route

```bash
# Dodaj preview
kamal-proxy deploy preview-123 \
  --target 172.18.0.5:3000 \
  --host 123.preview.domain.com

# Usuń preview
kamal-proxy remove preview-123

# Lista aktywnych
kamal-proxy list
```

### Dynamiczne — bez restartu

Routes dodawane/usuwane w runtime. Idealne dla preview: start kontenera → register route → stop → deregister.

### Wildcard subdomains

DNS: `*.preview.domain.com` → A record na serwer.
kamal-proxy: każdy preview ma explicit `--host` mapowanie. Nie potrzeba wildcard w proxy — wystarczy wildcard w DNS.

---

## Docker — izolacja untrusted code

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

| Flag | Co robi |
|---|---|
| `--memory=512m` | Hard limit RAM. OOM killer po przekroczeniu. |
| `--cpus=0.5` | Max pół core. Zapobiega CPU hogging. |
| `--pids-limit=100` | Zapobiega fork bombom. |
| `--cap-drop=ALL` | Zero Linux capabilities (no raw sockets, no mount, etc.) |
| `--no-new-privileges` | Nie może eskalować uprawnień. |
| `--network=preview-internal` | Sieć Docker `--internal` = brak outbound internet. |
| `--read-only` | Root filesystem read-only. |
| `--tmpfs /tmp` | Writable /tmp w RAM, ograniczone. |

### Network isolation

```bash
# Sieć bez outbound internetu
docker network create --internal preview-internal
```

Kontenery w `preview-internal` widzą siebie nawzajem ale nie mają routingu na zewnątrz. kamal-proxy na hoście forwarduje inbound HTTP do kontenerów.

Problem: kontenery mogą atakować inne kontenery w tej samej sieci.
Rozwiązanie: osobna sieć per kontener (overhead, ale max izolacja) lub `--network=none` + iptables rules.

Pragmatyczne podejście na start: `--network=preview-internal` + limit concurrent previews. Osobne sieci per kontener w przyszłości jeśli to stanie się problemem.

### SQLite — naturalna izolacja

Generowane apki używają SQLite (plik w kontenerze). Nie ma shared database servera. Każdy preview ma swoją izolowaną bazę. To eliminuje całą klasę problemów z multi-tenant DB.

---

## PreviewManager — implementacja

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
      "-f", standard_dockerfile_path,  # Dockerfile z naszego repo, nie z wygenerowanej apki
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

### Standardowy Dockerfile (nasz, nie wygenerowany)

Krytyczne: **nigdy nie używamy Dockerfile z wygenerowanej apki.** Używamy naszego standardowego Dockerfile.

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

### Optymalizacja czasu buildu

Pełny `docker build` z `bundle install` = 1-3 minuty. Za wolne na restart po iteracji.

**Base image z pre-installed gems:**

```dockerfile
# Budowany raz, aktualizowany rzadko
FROM ruby:3.3-slim AS base
RUN apt-get update && apt-get install -y build-essential libsqlite3-dev nodejs npm
RUN gem install bundler

# Pre-install common gems (Devise, Pagy, Tailwind, etc.)
COPY common_gemfile /tmp/Gemfile
RUN cd /tmp && bundle install --jobs 4

# ---
# Per-project image (szybki, bo większość gemów już jest)
FROM preview-base:latest
WORKDIR /app
COPY . .
RUN bundle install --jobs 4    # tylko nowe gemy
RUN bin/rails db:prepare
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

Z base image: build per-project = **10-30 sekund** (tylko nowe gemy + assets).

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

## Co rozwiązujemy, czego nie

### Rozwiązane

- **Filesystem isolation** — kontener nie widzi hosta
- **Process isolation** — pids-limit, cap-drop
- **Network isolation** — --internal network, brak egress
- **Resource limits** — memory, CPU, pids
- **Routing** — kamal-proxy, subdomeny
- **Database isolation** — SQLite per kontener
- **Privilege escalation** — no-new-privileges, cap-drop=ALL

### Nie rozwiązane (akceptowalne ryzyka na start)

- **Container-to-container** — kontenery w jednej sieci mogą siebie widzieć. Mitigacja: osobne sieci per kontener w przyszłości.
- **Docker escape** — Docker nie jest VM. Kernel jest shared. Mitigacja: to ryzyko na poziomie Linuxa, nie naszej aplikacji. Firecracker/gVisor jeśli będzie potrzebna głębsza izolacja.
- **Denial of service** — memory/CPU limited per kontener, ale wiele kontenerów = wiele zasobów. Mitigacja: limit aktywnych preview (np. 10 per serwer).
- **Cold start** — pierwszy build 1-3 min. Mitigacja: base image z pre-installed gems, potem 10-30s.

---

## Fazy wdrożenia

### PoC (teraz)
- `docker run` z security flags, bez kamal-proxy
- `localhost:{port}` per preview
- Ręczne cleanup

### MVP (pierwsi userzy)
- kamal-proxy na serwerze
- Docker `--internal` network
- PreviewManager z Solid Queue
- Auto-cleanup idle
- Base image z common gems
- Limit: 10 aktywnych preview

### Produkcja (skala)
- Osobna sieć per kontener
- Monitoring (memory, CPU, container count)
- Multiple serwery z load balancing
- gVisor/Firecracker opcjonalnie

---

## Wpływ na istniejące docs

- `happy-path.md` Krok 5 (Preview) — zaktualizować o kontenery zamiast raw `rails server`
- `agents-vs-workflows.md` W3 — dodać Docker build step
- `stack.md` — dodać Docker/kamal-proxy do stack generatora
- `index.md` — dodać link do tego dokumentu
