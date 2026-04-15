# Tor 2 — PoC głównej apki generatora

Rails skeleton + RubyLLM chat + Solid Queue job odpalający proven workflow z Toru 1 (`roast-spike/revision_workflow.rb`).

## Cel

Udowodnić end-to-end, że pipeline ze spike'a odpala się z poziomu Rails appki zamiast `new_app_driver.rb`. Driver staje się `ExecuteRevisionJob`, hardcoded `plans.rb` — Instruction + Revision w DB wywołane przez tool call z chatu RubyLLM.

Tor 1 pokazał, że Roast + Claude CLI działają. Tor 2 pokazuje, że potrafimy to opakować w apkę zgodną z `happy-path.md` i `agents-vs-workflows.md`.

## Definition of Done

Apka spełnia wszystkie poniższe:

1. Rails 8 + RubyLLM + Solid Queue + Solid Cable + Tailwind stoi na `bin/rails s`
2. User wpisuje opis aplikacji → chat odpowiada (RubyLLM chat.ask bez tools, baseline)
3. Po drugiej-trzeciej wymianie LLM wywołuje `CreateInstruction` tool → w DB powstaje `Instruction` + `Revision` × N
4. Solid Queue `ExecuteRevisionJob` odpala `bin/roast` z przeniesionym `revision_workflow.rb` w cwd workspace'u projektu
5. W `storage/workspaces/<project_id>/` powstaje prawdziwa Rails app z git historią — jedna rewizja = jeden commit
6. Status rewizji (generating/completed/failed) leci przez Turbo Stream do UI chatu
7. Po `instruction.completed` subscriber wrzuca `ChatFollowUpJob` → LLM woła `SuggestPrompts` → user widzi karty z propozycjami
8. Demo przechodzi na planie z poziomu chatu analogicznym do `TODO_LIST` ze spike'a (3 rewizje × Sonnet, zielone `rails test`, ~8 minut wall)
9. CLI mirror: `bin/generate full --prompt "..."` robi to samo bez UI — do debugowania i testów integracyjnych

## Świadome cięcia (NIE wchodzi w Tor 2)

| Odcięte | Gdzie to trafia |
|---------|-----------------|
| Preview (iframe z działającą apką) | Tor 3 — osobny plan oparty o `preview-isolation.md` (Kamal+Docker) |
| Cancel mid-workflow + SIGTERM na PID | Tor 2.5 lub Tor 3 — wymaga PID trackingu i process supervisora |
| Undo / `UndoLastChange` / W5 | Późniejszy tor — git revert jako nowa rewizja, ale architektonicznie oddzielne |
| Export ZIP / GitHub push (W7) | Późniejszy tor — UI action, nie krytyczne dla PoC |
| Multi-user / Devise w generatorze | Dev-only na Tor 2. Auth dodamy gdy apka wyjdzie poza moją maszynę |
| Archetype baza / rozbudowany research (D1) | Tor 2 używa uproszczonego promptu bez archetypów. Archetypy to osobny workstream contentowy |
| Real koszt w USD | Subskrypcja Claude Code pokrywa. Jednorazowy pomiar przez OpenRouter dopiero gdy DoD tego wymaga |
| UI polish (design system, mobile, dark mode) | Tailwind default wystarczy. Styling później |
| Remediation UI | Workflow ma remediation loop (spike to potwierdził). UI pokazuje tylko finalny status. Szczegóły remediation widoczne w logach subprocess'a |

Te wycięcia nie są na zawsze — to świadome zmniejszenie zakresu pierwszego szpilu.

## Architektura — skrót

Diagram pełny: `happy-path.md` § Architektura. Integracja warstw: `layer-integration.md`. Tutaj tylko shape specyficzny dla Toru 2.

```
HTTP request                           Solid Queue worker
     │                                       │
     ▼                                       ▼
┌─────────────┐     Notifications      ┌───────────────────┐
│ Chat view   │◄─────event bus─────────│ ExecuteRevisionJob│
│ Turbo Stream│     revision.started   │ - shells bin/roast│
│ + tools     │     revision.completed │ - revision_workflow│
│             │     instruction.done   │   w lib/roast/    │
└──────┬──────┘                        └────────┬──────────┘
       │ tool call                              │
       │ CreateInstruction                      │ Claude CLI
       ▼                                        ▼
┌─────────────┐                        ┌───────────────────┐
│ ChatRespond │                        │ storage/workspaces│
│ Job         │                        │ /<project_id>/    │
│ RubyLLM     │                        │  git repo + docs/ │
└─────────────┘                        └───────────────────┘
```

Kluczowe granice:

- **RubyLLM** żyje w `ChatRespondJob` i tool handlerach. Nie wie o Roast.
- **Roast** żyje w `ExecuteRevisionJob` jako shellowany subprocess (`bin/roast revision_workflow.rb`). Nie wie o RubyLLM ani DB — ENV-bound: `REVISION_WORKSPACE`, `CLAUDE_MODEL`, `INSTRUCTION_ID`.
- **Event bus** (`ActiveSupport::Notifications`) — jedyny most. Subscribers robią `perform_later` albo `broadcast_replace_to`, nic więcej.

## Model danych

Cytat z `happy-path.md` (kanoniczny). Tu tylko to co implementujemy w Tor 2:

```ruby
Project
  - name: string
  - workspace_path: string       # storage/workspaces/<id>/ (relatywne do Rails.root)
  has_one :chat
  has_many :instructions
  has_many :revisions

# Z RubyLLM (acts_as_chat / acts_as_message)
Chat
  belongs_to :project
  has_many :messages

Message
  belongs_to :chat
  - role: enum (user, assistant, tool)
  - content: text
  - tool_calls: jsonb            # RubyLLM to daje

Instruction
  belongs_to :project
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions
  - phase: enum (processing, completed, failed, cancelled)
  - description: text

Revision
  belongs_to :project
  belongs_to :instruction
  belongs_to :parent, class_name: "Revision", optional: true
  - git_sha: string
  - summary: text                # git commit message
  - prompt: text                 # pełny prompt do Claude CLI
  - position: integer            # 1-indexed w ramach Instruction
  - status: enum (pending, generating, completed, failed)
  - started_at / finished_at: datetime
  - metrics: jsonb               # wall_seconds, exit_code itd. — struktura z drivera
```

Odłożone z `happy-path.md`: `research_output` (nie używamy researchu D1 w PoC), `cli_pid` (nie implementujemy cancela w Torze 2).

## Przeniesienie spike'a do apki

`roast-spike/` zostaje jako reference implementation (żeby móc odpalać regresje bez Rails). Do apki kopiujemy w zmienionej formie:

| Ze spike'a | Do apki | Zmiany |
|------------|---------|--------|
| `revision_workflow.rb` | `lib/roast/revision_workflow.rb` | Zero — to już jest plik Roast DSL, odpalany przez CLI |
| `verify_revision.rb` | `lib/verify_revision.rb` albo `app/lib/verify_revision.rb` | Zero — moduł Ruby, zostaje taki sam |
| `new_app_driver.rb` | `app/jobs/execute_instruction_job.rb` | Logika orchestracji (`rails new` + pętla rewizji) staje się jobem |
| `bin/roast` | `bin/roast` w root apki | Zero — ten sam wrapper (unset ANTHROPIC_*, pin frum PATH) |
| `bin/roast-openrouter` | `bin/roast-openrouter` | Zero — fallback płatny, na razie nie używamy ale zostaje |
| `plans.rb` | — | Nie kopiujemy. Plany generuje LLM (Krok 4), a hardcoded TODO_LIST idzie do `test/fixtures/plans/` dla testów |

`Gemfile` apki: `ruby_llm`, `roast-ai (~> 1.1)`, `solid_queue`, `solid_cable`, `tailwindcss-rails`, `turbo-rails`, `stimulus-rails`. Ruby 4.0.2 (wymóg Roast 1.1).

**Uwaga na ENV hygiene** — trzy gotchas z `feedback_roast_rails_env_gotchas` są dalej aktualne:

1. `ANTHROPIC_API_KEY` leak → `bin/roast` wrapper dalej unsetuje. Rails app nie ma powodu eksportować klucza, ale ktoś może mieć w `.envrc` — wrapper to neutralizuje.
2. frum Ruby shim → wrapper pinuje `PATH`. Job musi wołać **`bin/roast`**, nie `bundle exec roast` bezpośrednio.
3. `BUNDLE_GEMFILE` leak w shellu do workspace → `VerifyRevision.with_clean_bundler_env` dalej rozwiązuje. W `ExecuteRevisionJob` dodatkowo: subprocess Roast dostaje czyste ENV (bez `BUNDLE_*`), wtedy Roast inicjalizuje się pod swoim Gemfilem (apki generatora), a verify w środku workflow'u shelluje do workspace z czystym env.

## Kroki

Każdy krok ma własny DoD. Zielone wszystkie = Tor 2 domknięty.

### Krok 1 — Rails skeleton + spike import (półdzień)

- `rails new generator --css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci`
- `.ruby-version` = `4.0.2` (to samo co spike — Roast 1.1 wymaga 3.3+, lepiej pin na to co działa)
- Gemfile — stack z `stack.md` § "Stack naszej aplikacji (generator)", plus dev: `debug`, `web-console`
- Solid Queue + Solid Cable skonfigurowane (`bin/rails solid_queue:install`, mount w `routes.rb` opcjonalnie)
- Skopiuj `revision_workflow.rb`, `verify_revision.rb`, `bin/roast`, `bin/roast-openrouter` do nowego Gemfile context
- Dodaj plik `tmp/smoke_workflow.sh` — odpala `bin/roast lib/roast/revision_workflow.rb` na pustym workspace z dummy kwargiem
- **DoD**: `bin/rails s` odpala (pusty root), smoke script przechodzi (workflow startuje, wysypuje się dopiero na braku workspace'u — dowodzi że wrapper + frum + Gemfile są ok)

### Krok 2 — Model danych + migracje (półdzień)

- Migration: `projects`, `chats`, `messages`, `instructions`, `revisions` wg schema wyżej
- RubyLLM scaffolding: `rails generate ruby_llm:install` → daje `Chat`/`Message` modele (mają `acts_as_chat`, persistencję messages i tool calls)
- Rozszerz `Chat`: `belongs_to :project`. Rozszerz `Message`: nic dodatkowego (RubyLLM wystarczy)
- Fixtures w `test/fixtures/` — 1 projekt, 1 chat, kilka wiadomości, 1 instruction z 2 rewizjami
- Model testy (minimalne): walidacje, associations, enum transitions
- **DoD**: `bin/rails test test/models` zielone

### Krok 3 — Chat baseline bez tools (pół-dzień)

- `ProjectsController#new, create, show` — formularz "opisz apkę" → `Project.create!` + `Chat.create!` + `Message.create!(role: :user)` → redirect do `/projects/:id`
- View `projects/show.html.erb` — Turbo Frame `chat`, partial `_message.html.erb`, pole input
- `ChatRespondJob`:
  ```ruby
  def perform(message_id)
    message = Message.find(message_id)
    chat = message.chat
    chat.ask(message.content)          # RubyLLM sam persistuje assistant message
    chat.messages.last.broadcast_append_to("chat_#{chat.id}")
  end
  ```
- Po `Message.create!(role: :user)` z kontrolera — `ChatRespondJob.perform_later`
- **DoD**: user tworzy projekt, pisze "zrób listę todo", widzi odpowiedź LLM, może kontynuować wymianę. Bez tools, bez generowania — sam chat.

### Krok 4 — Tools: `CreateInstruction` + `SuggestPrompts` (dzień)

- Klasy tooli w `app/tools/`:
  ```ruby
  class CreateInstruction < RubyLLM::Tool
    description "Startuje generowanie aplikacji. Wywołaj gdy user zaakceptował plan."
    param :description, type: :string, desc: "Opis całej instrukcji (git-commit-able)"
    param :revisions, type: :array, desc: "Lista rewizji: [{ summary, prompt }, ...]"

    def execute(description:, revisions:)
      project = Current.project  # thread-local ustawiony w ChatRespondJob
      instruction = project.instructions.create!(
        description: description,
        phase: :processing,
        anchor_message: project.chat.messages.last
      )
      revisions.each_with_index do |r, i|
        instruction.revisions.create!(
          project: project,
          summary: r[:summary],
          prompt: r[:prompt],
          position: i + 1,
          status: :pending,
          parent: i == 0 ? nil : instruction.revisions[i - 1]
        )
      end
      ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: instruction.id)
      { instruction_id: instruction.id, revision_count: revisions.size }
    end
  end

  class SuggestPrompts < RubyLLM::Tool
    description "Proponuje userowi co dalej. UI rendruje jako klikalne karty."
    param :prompts, type: :array, desc: "Lista sugerowanych promptów, każdy ma tekst z opcjonalnymi lukami ___"

    def execute(prompts:)
      # Tool result persistowany przez RubyLLM w message.tool_calls.
      # UI czyta ostatni tool result z role=tool i rendruje karty.
      { prompts: prompts }
    end
  end
  ```
- `ChatRespondJob` dostaje tools:
  ```ruby
  chat.ask(message.content, tools: [CreateInstruction, SuggestPrompts])
  ```
- System prompt (w `Chat.create!` albo w inicjalizacji RubyLLM dla projektu):
  - "Jesteś generatorem aplikacji Rails. Gdy user opisuje apkę, zadaj max 2 pytania uściślające (guided). Potem wywołaj CreateInstruction z planem rewizji (3-6 kroków, Rails Way, Tailwind, Hotwire, Devise)."
  - Reference: `stack.md` — co może być w planie, czego nie (Redis, React)
- Subscriber: `ActiveSupport::Notifications.subscribe("instruction.requested")` → `ExecuteInstructionJob.perform_later(id)` (na razie pusta implementacja — zaślepka, która tylko loguje)
- UI: partial `_suggested_prompts.html.erb` renderuje `tool_calls[:SuggestPrompts][:prompts]` jako klikalne karty (klik → POST do `/projects/:id/messages` z tekstem karty)
- **DoD**: user pisze "todo list", LLM odpowiada planem w treści + wywołuje CreateInstruction (Instruction + 3 Revisions w DB), sugeruje prompty w następnej turze. Jeszcze nic się nie generuje — job jest zaślepką.

### Krok 5 — `ExecuteInstructionJob` + integracja Roast (1-2 dni)

To jest najmiesnistsza część. Przenosi całą logikę z `new_app_driver.rb` do Rails joba z persystencją statusu.

```ruby
class ExecuteInstructionJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = Rails.root.join("storage/workspaces/#{project.id}").to_s

    prepare_workspace(project, workspace) unless project.workspace_initialized?
    rails_new(project, workspace) unless File.exist?(File.join(workspace, "Gemfile"))
    init_docs_baseline(workspace) unless File.exist?(File.join(workspace, "docs"))

    instruction.revisions.order(:position).each do |revision|
      execute_revision(revision, workspace)
      break if revision.failed?
    end

    instruction.update!(phase: instruction.revisions.all?(&:completed?) ? :completed : :failed)
    ActiveSupport::Notifications.instrument(
      instruction.completed? ? "instruction.completed" : "instruction.failed",
      instruction_id: instruction.id
    )
  end

  private

  def execute_revision(revision, workspace)
    revision.update!(status: :generating, started_at: Time.current)
    ActiveSupport::Notifications.instrument("revision.started", revision_id: revision.id)

    env = {
      "REVISION_WORKSPACE" => workspace,
      "CLAUDE_MODEL" => ENV.fetch("CLAUDE_MODEL", "sonnet")
    }
    args = [
      Rails.root.join("bin/roast").to_s,
      Rails.root.join("lib/roast/revision_workflow.rb").to_s,
      "--",
      "revision_id=#{revision.id}",
      "revision_summary=#{revision.summary}",
      "revision_prompt=#{revision.prompt}"
    ]

    started = Time.current
    ok = system(env, *args)
    exit_code = $?.exitstatus
    wall = Time.current - started

    metrics = {
      wall_seconds: wall.round(2),
      exit_code: exit_code,
      git_sha: git_head(workspace)
    }

    if ok
      revision.update!(status: :completed, finished_at: Time.current, git_sha: metrics[:git_sha], metrics: metrics)
      ActiveSupport::Notifications.instrument("revision.completed", revision_id: revision.id, git_sha: metrics[:git_sha])
    else
      revision.update!(status: :failed, finished_at: Time.current, metrics: metrics)
      ActiveSupport::Notifications.instrument("revision.failed", revision_id: revision.id, error: "exit #{exit_code}")
    end
  end

  # rails_new, init_docs_baseline, git_head — cut/paste z new_app_driver.rb
end
```

Dodatkowo:

- `app/jobs/application_job.rb`: `queue_as :generation` + `retry_on StandardError, wait: :polynomially_longer, attempts: 1` (generowanie nie retryujemy automatycznie — po failu user decyduje)
- Solid Queue config: queue `generation` z concurrency 1 (jedno generowanie na raz, happy-path.md § "Równoległe instrukcje" — jedna aktywna)
- `storage/workspaces/` dodane do `.gitignore`
- Timeout — na razie bez twardego timeout'u. Obserwujemy, czy rewizja nie utyka (spike mierzony: max 226s). Twardy timeout (np. 20 min) dopiszemy w Kroku 7 jeśli będzie potrzeba
- **DoD**: ręcznie utworzona Instruction + 1 Revision → `ExecuteInstructionJob.perform_now(id)` → powstaje Rails app w workspace, git ma 2 commity (scaffolding baseline + rewizja), Revision w DB ma `status=completed` i `git_sha`

### Krok 6 — Eventy + Turbo Streams + follow-up (półdzień)

- `config/initializers/event_subscribers.rb`:
  ```ruby
  %w[revision.started revision.completed revision.failed].each do |event|
    ActiveSupport::Notifications.subscribe(event) do |*, payload|
      revision = Revision.find(payload[:revision_id])
      Turbo::StreamsChannel.broadcast_replace_to(
        revision.project,
        target: "revision_#{revision.id}",
        partial: "revisions/revision",
        locals: { revision: revision }
      )
    end
  end

  ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
    ChatFollowUpJob.perform_later(payload[:instruction_id], event: :completed)
  end

  ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
    ChatFollowUpJob.perform_later(payload[:instruction_id], event: :failed)
  end
  ```
- `ChatFollowUpJob`:
  ```ruby
  def perform(instruction_id, event:)
    instruction = Instruction.find(instruction_id)
    chat = instruction.project.chat
    prompt = event == :completed ?
      "Generowanie zakończone. Zaproponuj 3-5 naturalnych kolejnych kroków (SuggestPrompts tool)." :
      "Rewizja #{instruction.revisions.failed.first&.summary} nie przeszła weryfikacji. Wyjaśnij userowi co się stało i zaproponuj podejście."
    chat.ask(prompt, tools: [CreateInstruction, SuggestPrompts])
  end
  ```
- View: `app/views/revisions/_revision.html.erb` z `turbo-frame id="revision_<%= revision.id %>"` renderuje status badge (pending/generating/completed/failed) + git SHA dla completed
- W `projects/show.html.erb` nad chatem: lista aktywnych rewizji (Instruction.processing → Revisions)
- **DoD**: odpalenie pełnej Instruction z UI → user widzi live progress (pending → generating → completed per rewizja), po zakończeniu chatbox dostaje nową wiadomość z sugestiami

### Krok 7 — E2E demo: "todo list" plan + CLI (półdzień)

- Integration test `test/integration/generate_todo_list_test.rb`:
  - Tworzy projekt, wysyła wiadomość "Prosta lista todo, Tailwind"
  - Stub RubyLLM `chat.ask` na deterministyczną odpowiedź — od razu wywołuje `CreateInstruction` z planem TODO_LIST ze spike'a (fixture)
  - `ExecuteInstructionJob.perform_now` — real subprocess (nie stub, to jest E2E)
  - Assert: `instruction.reload.completed?`, `project.revisions.count == 3`, `git log` w workspace ma 3+1 (scaffolding) commitów, `rails test` w workspace zielony
  - Pomiar: `wall_time < 900s` (15 min z zapasem nad 496s ze spike'a)
- CLI mirror w `bin/generate`:
  - `bin/generate full --prompt "..."` — tworzy projekt + wymusza CreateInstruction (stub LLM jak w teście) + odpala job synchronicznie
  - `bin/generate respond --project-id=N` — ręczne triggerowanie ChatRespondJob
  - `bin/generate execute --instruction-id=N` — synchroniczne ExecuteInstructionJob (debugging bez Solid Queue workera)
- **DoD**: `bin/rails test` green (unit + integration), `bin/generate full --prompt "..."` przechodzi end-to-end, manual demo przez UI działa

## Ryzyka i co z nimi zrobić

| Ryzyko | Mitigacja |
|--------|-----------|
| RubyLLM niekonsekwentnie woła CreateInstruction | System prompt z jawnym `Musisz wywołać CreateInstruction` + few-shot. Fallback: UI button "Zacznij generować" który wymusza tool call z treścią chatu jako opis |
| Subprocess `bin/roast` zawiesza się | Krok 7 obserwuje, twardy timeout 20min dodamy jeśli zdarzy się częściej niż 1/10. Wcześniej: Solid Queue ma job timeout konfigurowalny, bardziej diagnoza niż blocker |
| RubyLLM Chat/Message schema konflikt z własnymi kolumnami | Najpierw run `rails generate ruby_llm:install`, potem pisanie migracji Instruction/Revision. Jeśli potrzeba custom field na Message — extension model zamiast kolumny |
| Solid Queue + długi subprocess blokuje workera | Concurrency=1 na kolejce `generation` jest OK (jedna instrukcja na raz z definicji). Jeśli zablokuje też inne kolejki → osobny worker process dla `generation` |
| Claude CLI rate limit na subskrypcji | Spike pokazał że 3 rewizje × Sonnet są OK. Przy demo dla dwóch użytkowników naraz może dojść limit → reject drugiej instrukcji z retry-after, nie równoległość |
| Workspace path w DB absolutne → migrowalność | W DB trzymamy **relatywne** (np. `storage/workspaces/123`), absolutizujemy w jobie przez `Rails.root.join`. Przy restoragu/zmianie hosta reset workspace_path, workspace recreate jest dopuszczalny (wszystko w git) |
| `rails new` w subprocess nadpisuje `.ruby-version` generatora | `rails_new` wywoływany z `chdir: workspace_root`, a sama komenda tworzy podkatalog. Generator ma `.ruby-version` w roocie, workspace też dostaje swoje. Ale **UWAGA**: sprawdzić czy `bundle` w workspace nie używa frum shima generatora — `VerifyRevision.with_clean_bundler_env` powinno to załatwić (zweryfikowane w spike) |

## Otwarte pytania (do decyzji w trakcie)

1. **Plany: LLM-generated czy hardcoded archetype template?** PoC: LLM generuje z promptu. Jakość planu to realne ryzyko — jeśli okaże się chwiejna, dodamy few-shot z 3-4 archetypami jako reference. Decyzja w Kroku 4 po pierwszych testach
2. **Workspace per projekt vs shared?** Per projekt (`storage/workspaces/<id>`). Shared bundle cache (`~/.bundle`) żeby nie reinstalować gemów przy każdym `rails new` — do optymalizacji w Kroku 5 jeśli wall time Krok 7 przekroczy limit
3. **Process supervisor dla subprocess Roast?** Start: plain `system()`. Jeśli okaże się że potrzebujemy timeoutu + kill + PID tracking — minimum `Process.spawn` + wątek watchdog. Pełny supervisor (np. Dragonfly) dopiero gdy Tor 2.5 (cancel) ruszy
4. **Czy RubyLLM chat dostaje kontekst o `Project.revisions`?** Happy-path mówi tak. W Tor 2 PoC: tak, przez `chat.with_instructions(...)` ustawiane w `ChatRespondJob` każdorazowo (nie w `Chat.create!`) żeby odświeżać stan. Format: short markdown summary z listą revision summaries + statusów

## Oszacowanie

- Krok 1 — 0.5 dnia
- Krok 2 — 0.5 dnia
- Krok 3 — 0.5 dnia
- Krok 4 — 1 dzień
- Krok 5 — 1.5-2 dni
- Krok 6 — 0.5 dnia
- Krok 7 — 0.5 dnia

Razem: **5-6 dni fokusa**. Realny kalendarz pewnie 1.5-2 tygodnie przy przerywaniu.

## Alternatywne podejścia (do rozważenia przy powrocie)

Każda z poniższych decyzji jest odwracalna. Opisane dla przyszłego-mnie / Pawła po /clear — żeby nie przepatrywać ponownie całego rozumowania.

### A1. Subprocess `bin/roast` vs. native Ruby embedding

**Plan**: Job woła `bin/roast revision_workflow.rb` przez `system()` z ENV-passingiem. Subprocess izolacja + za darmo session replay + wrapper leczy 3 ENV leaks.

**Alternatywa**: Załadować Roast jako gem do apki (`require "roast"`) i odpalać workflow in-process (`Roast::Workflow.load(path).execute(kwargs)`). Zero subprocess overhead, łatwiejszy debugger/stack trace, prościej przekazywać obiekty (np. `instruction` zamiast `instruction_id` przez ENV).

**Dlaczego wybrane subprocess**: Spike to walidował. Wrapper `bin/roast` już rozwiązuje ANTHROPIC_API_KEY leak + frum shim. In-process wymaga rozwiązania tych gotchas w Ruby (unset ENV w Bundler.with_unbundled_env? Reloadery Rails nie pokochają).

**Kiedy reconsiderować**: gdy obserwujemy że subprocess startup to znaczący % czasu rewizji (spike pokazuje ~226s per rewizja → startup <1% → unimportant). Albo gdy zaczniemy potrzebować streamowania logów z Roasta do UI w real-time — subprocess pipe to robi, ale live Turbo Stream z in-process workflow byłby czystszy.

### A2. Claude CLI vs. RubyLLM do generacji kodu

**Plan**: `agent(:generate_code)` w Roast woła Claude CLI (subskrypcja, file tools + bash).

**Alternatywa**: Zastąpić agentem RubyLLM z customowymi toolami (WriteFile, RunBash, ReadFile). Wszystko w jednym procesie, spójny LLM client, łatwiej testować.

**Dlaczego wybrane Claude CLI**: Darmowe (subskrypcja) dla PoC, proven w spike'u, ma battle-tested tooling. RubyLLM+tools wymagałby napisania warstwy agentowej od zera — duży workstream.

**Kiedy reconsiderować**: gdy subskrypcja Claude Code przestaje pokrywać koszt (limity API), albo gdy chcemy dać userom własne klucze Anthropic/OpenRouter. Wtedy RubyLLM daje kontrolę nad ile tokenów per user.

### A3. Roast jako orchestrator vs. plain Ruby job

**Plan**: `ExecuteInstructionJob` loops po rewizjach → każda woła Roast workflow. W2 (verify + remediation + commit) jest w Roast DSL.

**Alternatywa**: Usunąć Roast całkowicie. `ExecuteRevisionJob` w plain Ruby: `build_prompt → claude_cli → verify → remediation loop → git commit → update docs → commit docs`. Mniej zależności, wszystko w Rails idiom.

**Dlaczego wybrane Roast**: Session replay za darmo (dla Pawła jako debug tool), DSL narzuca strukturę, Shopify testuje to w produkcji, spike zwalidował end-to-end.

**Kiedy reconsiderować**: gdy Roast DSL okaże się bardziej frustrujący niż pomocny (3 gotchas ze spike'a to już sygnał). Gdy dołożymy wymagania którym Roast nie sprzyja (np. real-time streaming do UI, complex branching workflows). Plain Ruby byłby 200-300 linii — nie duży koszt przepisania.

### A4. Workspace: lokalny filesystem vs. container / tmpdir

**Plan**: `storage/workspaces/<project_id>/` na lokalnym filesystem.

**Alternatywa A**: `Dir.mktmpdir` per instruction — workspace efemeryczny, po instrukcji archiwizowany jako git bundle w Active Storage. Czysciej, ale bez incremental iteracji (Krok 6 z `happy-path.md`).

**Alternatywa B**: Od razu Docker container per projekt (jak w `preview-isolation.md`). Łączy Tor 2 z Tor 3.

**Dlaczego wybrany lokalny FS**: Najprostszy do debugowania (mogę `cd storage/workspaces/123/` i zobaczyć stan), wystarczający dla single-user PoC, kompatybilny z incremental iteracją.

**Kiedy reconsiderować**: gdy wychodzimy poza dev-only (multi-user → izolacja konieczna), gdy workspace state zaczyna kolidować z `rails new` w różnych katalogach, albo gdy chcemy testować generator w CI (tam tmpdir ma sens).

### A5. Jedno job per Instruction vs. per Revision

**Plan**: `ExecuteInstructionJob` w pętli robi wszystkie rewizje sekwencyjnie.

**Alternatywa**: `ExecuteRevisionJob` chainowany przez after_perform — każda rewizja osobny job, lepsza observability (Solid Queue UI), retry granularny per rewizja.

**Dlaczego wybrany jeden job**: Prostsza kontrola flow (break na failure, workspace state między rewizjami jest w pamięci joba), mniej glue code. Spike robił tak samo.

**Kiedy reconsiderować**: gdy chcemy retry pojedynczej failed rewizji bez odpalania całej Instruction (scenariusz "W3 padło na bug w promcie, napraw prompt, retry tylko W3"). Wtedy per-revision job daje to za darmo.

### A6. Plan: LLM-generated vs. archetype template + slot-filling

**Plan**: LLM generuje plan rewizji ad-hoc z promptu usera + system prompt z zasadami stack'u.

**Alternatywa**: Biblioteka archetypów (`archetypes/ecommerce.yml`, `archetypes/saas.yml`, ...) z template'ami planów. LLM tylko wybiera archetyp + wypełnia sloty (nazwa apki, konkretne pola modeli).

**Dlaczego wybrane ad-hoc**: Szybciej do PoC, elastyczne dla promptów spoza archetypów, daje sygnał jak dobrze LLM radzi sobie sam (baseline do porównania z archetypami później).

**Kiedy reconsiderować**: gdy jakość planów okaże się zmienne (niektóre są OK, niektóre gubią kroki). Archetype to core IP projektu (`index.md` § Wizja) — prędzej czy później i tak trzeba. Ale na Tor 2 to over-scope.

### A7. Chat tools vs. structured output (JSON)

**Plan**: LLM wywołuje `CreateInstruction` tool z parametrami.

**Alternatywa**: RubyLLM z response_format: json_schema. LLM odpowiada JSON-em, parser tworzy Instruction. Tools nie są używane.

**Dlaczego wybrane tools**: Canonical pattern RubyLLM, wspiera multi-turn (LLM może wywołać tool i kontynuować chat), pasuje do filozofii `happy-path.md` (tool calls = jedyny sposób triggerowania akcji).

**Kiedy reconsiderować**: gdy tool reliability okaże się problemem (LLM nie woła tool w spodziewanym momencie). Structured output jest deterministyczny — parser zawsze dostaje JSON albo error.

---

## Kontekst do wczytania przy powrocie (po /clear)

Jeśli wracasz do tego planu w nowej sesji, przeczytaj **w tej kolejności**:

1. **Ten plik (`tor-2-plan.md`)** — plan + alternatywy + otwarte pytania
2. **`roast-spike/findings.md`** — co zostało zwalidowane w Torze 1, jakie gotchas ujawnione
3. **`happy-path.md`** — full user story, model danych, architektura (kanon)
4. **`agents-vs-workflows.md`** — W1-W6 workflow definitions, Roast example (zsynchronizowany ze spike'iem)
5. **`layer-integration.md`** — event bus, RubyLLM↔Roast↔Solid Queue
6. **`stack.md`** — gemy (stack generatora vs. stack generowanych apek)

Dodatkowo — pliki spike'a które są proof-of-concept do skopiowania do Toru 2:
- `roast-spike/revision_workflow.rb` — W2 DSL
- `roast-spike/verify_revision.rb` — verify helper
- `roast-spike/new_app_driver.rb` — logika którą przenosimy do `ExecuteInstructionJob`
- `roast-spike/bin/roast` — wrapper rozwiązujący 3 ENV gotchas

Pamięci projektowe (`~/.claude/.../memory/`) relevantne:
- `feedback_roast_rails_env_gotchas.md` — 3 ENV leaks i fixy
- `reference_roast_dsl_gotchas.md` — Roast 1.1 DSL gotchas (metadata, .error, WORKFLOW_STATE)
- `project_rails_app_generator_openrouter.md` — bin/roast vs bin/roast-openrouter

## Wyjścia z Toru 2

Po domknięciu:

- **Dalej po warstwę preview** (Tor 3) — `preview-isolation.md` z Kamal+Docker, osobny plan
- **Albo polish PoC dla demo** — lepszy UI, cancel, kilka archetypów, żeby pokazać na Tropical/Rails World jako demo
- **Albo monetyzacja / sponsorship** — token costs liczone, teraz mamy dane do rozmowy z Anthropic local ambassadors

Decyzję odłożyć do momentu gdy Tor 2 zamknie się. Na dziś: Tor 2 jest niezależny od każdego z tych kierunków.
