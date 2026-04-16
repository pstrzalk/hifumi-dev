# Faza 2 — PoC głównej apki generatora

Rails skeleton + RubyLLM chat + Solid Queue job odpalający proven workflow z Fazy 1 (`../../spikes/roast/revision_workflow.rb`).

## Cel

Udowodnić end-to-end, że pipeline ze spike'a odpala się z poziomu Rails appki zamiast `new_app_driver.rb`. Driver staje się `ExecuteInstructionJob`, hardcoded `plans.rb` — Instruction + Revision w DB wywołane przez tool call z chatu RubyLLM (poprzez service `CreatePlan`).

Faza 1 pokazała, że Roast + Claude CLI działają. Faza 2 pokazuje, że potrafimy to opakować w apkę zgodną z `../01-vision/02-user-journey.md` i `../02-architecture/01-workflows-and-decisions.md`.

## Decyzje architektoniczne (potwierdzone 2026-04-16)

Przejście przez alternatywy A1-A7. Większość potwierdziła default planu; dwie zmiany architektoniczne + jedno uściślenie scope'u.

| # | Decyzja | Zmiana vs. default |
|---|---------|--------------------|
| A1 | **Subprocess `bin/roast`** — wrapper neutralizuje 3 ENV gotchas | = plan |
| A2 | **Claude CLI** jako agent w Roast; `bin/roast-openrouter` fallback | = plan |
| A3 | **Roast** jako orchestrator; `revision_workflow.rb` przenoszony 1:1 | = plan |
| A4 | **Lokalny FS** (`storage/workspaces/<id>/`) w PoC; **produkcyjnie izolacja userów → Faza 3** (jawny wymóg, nie tylko consequence preview) | = plan + explicit Faza 3 TODO |
| A5 | **Jeden `ExecuteInstructionJob`** z pętlą po rewizjach; chainowanie per Revision jako przyszłe rozszerzenie | = plan |
| A6 | **`CreatePlan` service jako abstrakcja** z pierwszą implementacją `CreatePlan::AdHocLLM`; swap'owalne (archetype, hybrid, cheap-but-good model) w przyszłości. Jakość planów = klucz do jakości generatora, ale osobny workstream poza Fazą 2 | **ZMIANA**: dodana warstwa abstrakcji, tool nie tworzy planu bezpośrednio |
| A7 | **Lightweight tool `StartGeneration(intent, clarifications)`** — detailed prompts NIE wychodzą przez chat API. Secret sauce (prompt engineering plannera) żyje wewnątrz `CreatePlan`, nie w system prompcie chatu ani w tool call args | **ZMIANA**: tool przekazuje intent zamiast completed plan |

**Konsekwencje dla reszty planu**:
- Krok 4: tool nazywa się `StartGeneration`, deleguje do `CreatePlan.call(intent, clarifications)`, a ten zwraca Revisions
- System prompt chatu nie zawiera reguł typu "Rails Way, 3-6 kroków, Tailwind" — te reguły żyją wewnątrz `CreatePlan::AdHocLLM`'s internal prompt
- Model Instruction: `description` generowany przez `CreatePlan` (human-readable, git-commit-able); rozważyć osobne `user_intent: text` na raw input z chatu (do decyzji w Kroku 4)

## Definition of Done

Apka spełnia wszystkie poniższe:

1. Rails 8 + RubyLLM + Solid Queue + Solid Cable + Tailwind stoi na `bin/rails s`
2. User wpisuje opis aplikacji → chat odpowiada (RubyLLM chat.ask bez tools, baseline)
3. Po drugiej-trzeciej wymianie LLM wywołuje `StartGeneration(intent, clarifications)` tool → `CreatePlan` service generuje rewizje → w DB powstaje `Instruction` + `Revision` × N
4. Solid Queue `ExecuteInstructionJob` odpala `bin/roast` z przeniesionym `revision_workflow.rb` w cwd workspace'u projektu
5. W `storage/workspaces/<project_id>/` powstaje prawdziwa Rails app z git historią — jedna rewizja = jeden commit
6. Status rewizji (generating/completed/failed) leci przez Turbo Stream do UI chatu
7. Po `instruction.completed` subscriber wrzuca `ChatFollowUpJob` → LLM woła `SuggestPrompts` → user widzi karty z propozycjami (prompts mogą być hintami dla chatu, ale detailed plan kolejnej rewizji dalej generuje `CreatePlan`)
8. Demo przechodzi na planie z poziomu chatu analogicznym do `TODO_LIST` ze spike'a (3 rewizje × Sonnet, zielone `rails test`, ~8 minut wall)
9. CLI mirror: `bin/generate full --prompt "..."` robi to samo bez UI — do debugowania i testów integracyjnych

## Świadome cięcia (NIE wchodzi w Fazę 2)

| Odcięte | Gdzie to trafia |
|---------|-----------------|
| Preview (iframe z działającą apką) | Faza 3 — osobny plan oparty o `02-phase-3-preview-isolation.md` (Kamal+Docker) |
| Cancel mid-workflow + SIGTERM na PID | Faza 2.5 lub Faza 3 — wymaga PID trackingu i process supervisora |
| Undo / `UndoLastChange` / W5 | Późniejsza faza — git revert jako nowa rewizja, ale architektonicznie oddzielne |
| Export ZIP / GitHub push (W7) | Późniejsza faza — UI action, nie krytyczne dla PoC |
| Multi-user / Devise w generatorze | Dev-only w Fazie 2. Auth dodamy gdy apka wyjdzie poza moją maszynę |
| Archetype baza / rozbudowany research (D1) | Faza 2 używa uproszczonego promptu bez archetypów. Archetypy to osobny workstream contentowy |
| Real koszt w USD | Subskrypcja Claude Code pokrywa. Jednorazowy pomiar przez OpenRouter dopiero gdy DoD tego wymaga |
| UI polish (design system, mobile, dark mode) | Tailwind default wystarczy. Styling później |
| Remediation UI | Workflow ma remediation loop (spike to potwierdził). UI pokazuje tylko finalny status. Szczegóły remediation widoczne w logach subprocess'a |

Te wycięcia nie są na zawsze — to świadome zmniejszenie zakresu pierwszego szpilu.

## Architektura — skrót

Diagram pełny: `../01-vision/02-user-journey.md` § Architektura. Integracja warstw: `../02-architecture/02-layer-integration.md`. Tutaj tylko shape specyficzny dla Fazy 2.

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

Cytat z `../01-vision/02-user-journey.md` (kanoniczny). Tu tylko to co implementujemy w Fazie 2:

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

Odłożone z `../01-vision/02-user-journey.md`: `research_output` (nie używamy researchu D1 w PoC), `cli_pid` (nie implementujemy cancela w Fazie 2).

## Przeniesienie spike'a do apki

`../../spikes/roast/` zostaje jako reference implementation (żeby móc odpalać regresje bez Rails). Do apki kopiujemy w zmienionej formie:

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

Każdy krok ma własny DoD. Zielone wszystkie = Faza 2 domknięta.

### Krok 1 — Rails skeleton + spike import (półdzień)

- `rails new generator --css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci`
- `.ruby-version` = `4.0.2` (to samo co spike — Roast 1.1 wymaga 3.3+, lepiej pin na to co działa)
- Gemfile — stack z `../02-architecture/03-tech-stack.md` § "Stack naszej aplikacji (generator)", plus dev: `debug`, `web-console`
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

### Krok 4 — Tools: `StartGeneration` + `SuggestPrompts` + service `CreatePlan` (dzień)

**Kluczowa zasada** (z decyzji A7): detailed prompts do Claude CLI **nigdy nie opuszczają backendu**. Chat LLM dostaje tylko informację że user jest gotowy + jego intencje; całe prompt engineering plannera (secret sauce) żyje w `CreatePlan` service.

- Service `app/services/create_plan.rb` (abstrakcja z A6):
  ```ruby
  module CreatePlan
    # Interface: wszystkie implementacje muszą zwracać tablicę hashy gotowych
    # do Revision.create!. Adapter-pattern — swappable przez config lub A/B.
    def self.call(intent:, clarifications: {}, context: {})
      implementation.call(intent: intent, clarifications: clarifications, context: context)
    end

    def self.implementation
      # Na start: AdHocLLM. Później: Archetypes, Hybrid, CheapButGood
      @implementation ||= AdHocLLM
    end

    class AdHocLLM
      # Wewnętrzne LLM call z własnym system promptem (SECRET SAUCE)
      # System prompt zawiera reguły: "Rails Way, 3-6 kroków, Tailwind, Hotwire, Devise..."
      # NIE jest to widoczne dla chat LLM ani dla usera
      def self.call(intent:, clarifications:, context:)
        # RubyLLM.chat z response_format: json_schema lub osobny tool call
        # zwraca: [{ summary: "...", prompt: "..." }, ...]
      end
    end

    # Przyszłe implementacje: Archetypes, Hybrid... — osobny workstream
  end
  ```

- Tool `app/tools/start_generation.rb`:
  ```ruby
  class StartGeneration < RubyLLM::Tool
    description "Startuje generowanie aplikacji. Wywołaj gdy user opisał co chce i jesteś gotowy."
    param :intent, type: :string, desc: "Plain language: co user chce zbudować, np. 'sklep z kwiatami z magazynem i Stripe'"
    param :clarifications, type: :object, desc: "Odpowiedzi na doprecyzowujące pytania: { key: value }"

    def execute(intent:, clarifications: {})
      project = Current.project
      revisions_data = CreatePlan.call(
        intent: intent,
        clarifications: clarifications,
        context: { project_id: project.id }
      )

      instruction = project.instructions.create!(
        user_intent: intent,            # raw z chatu, do audytu
        description: revisions_data.first[:instruction_description] || intent.truncate(200),
        phase: :processing,
        anchor_message: project.chat.messages.last
      )
      revisions_data.each_with_index do |r, i|
        instruction.revisions.create!(
          project: project,
          summary: r[:summary],
          prompt: r[:prompt],           # detailed prompt — żyje tylko w DB i ExecuteInstructionJob
          position: i + 1,
          status: :pending,
          parent: i == 0 ? nil : instruction.revisions[i - 1]
        )
      end
      ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: instruction.id)

      # WAŻNE: do chatu wraca TYLKO high-level confirmation, nie prompts
      { instruction_id: instruction.id, revision_count: revisions_data.size, intent: intent }
    end
  end
  ```

- Tool `app/tools/suggest_prompts.rb`:
  ```ruby
  class SuggestPrompts < RubyLLM::Tool
    description "Proponuje userowi co dalej. UI rendruje jako klikalne karty."
    param :prompts, type: :array, desc: "Lista sugerowanych promptów — user-facing, krótkie, plain language"

    def execute(prompts:)
      { prompts: prompts }
    end
  end
  ```

- `ChatRespondJob` dostaje tools:
  ```ruby
  chat.ask(message.content, tools: [StartGeneration, SuggestPrompts])
  ```

- **System prompt chatu (NIE zawiera reguł generowania planu)**:
  - "Jesteś asystentem pomagającym userom opisać jaką apkę Rails chcą zbudować. Zadaj max 2 pytania doprecyzowujące. Gdy user jest gotowy — wywołaj `StartGeneration(intent, clarifications)` przekazując PLAIN LANGUAGE opis tego co chcą. NIE generuj planu implementacji, nie wymieniaj modeli ani kontrolerów — to nie twoje zadanie."
  - Reguły "Rails Way, 3-6 kroków, Tailwind, Hotwire, Devise" **NIE są tu** — żyją w `CreatePlan::AdHocLLM`'s internal prompt

- Subscriber: `ActiveSupport::Notifications.subscribe("instruction.requested")` → `ExecuteInstructionJob.perform_later(id)` (na razie zaślepka)

- UI: partial `_suggested_prompts.html.erb` renderuje `tool_calls[:SuggestPrompts][:prompts]` jako klikalne karty

- Model danych uzupełnienie: `Instruction.user_intent: text` (raw intent z chatu, do audytu + widoczny w UI), `Instruction.description: text` (human-readable, do commit messages — generowany przez `CreatePlan`)

- **DoD**: user pisze "todo list", LLM zadaje 0-2 pytania i wywołuje `StartGeneration(intent: "prosta lista todo z Tailwind", clarifications: {...})`. `CreatePlan::AdHocLLM` generuje wewnętrznie 3 rewizje z detailed prompts. W DB powstaje Instruction + 3 Revisions. Chat kontynuuje "Zacząłem budować, oto co się dzieje..." bez odsłaniania prompts.

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
- Solid Queue config: queue `generation` z concurrency 1 (jedno generowanie na raz, ../01-vision/02-user-journey.md § "Równoległe instrukcje" — jedna aktywna)
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
| RubyLLM niekonsekwentnie woła StartGeneration | System prompt z jawnym `Musisz wywołać StartGeneration` + few-shot. Fallback: UI button "Zacznij generować" który wymusza tool call z treścią chatu jako intent |
| `CreatePlan::AdHocLLM` generuje plany o nierównej jakości | Logujemy każdą generację (intent → revisions) do DB. Po 5-10 runach analiza — jeśli jakość zmienne, decyzja czy implementować `CreatePlan::Archetypes` lub hybrid. Fallback nie jest blokerem PoC |
| Subprocess `bin/roast` zawiesza się | Krok 7 obserwuje, twardy timeout 20min dodamy jeśli zdarzy się częściej niż 1/10. Wcześniej: Solid Queue ma job timeout konfigurowalny, bardziej diagnoza niż blocker |
| RubyLLM Chat/Message schema konflikt z własnymi kolumnami | Najpierw run `rails generate ruby_llm:install`, potem pisanie migracji Instruction/Revision. Jeśli potrzeba custom field na Message — extension model zamiast kolumny |
| Solid Queue + długi subprocess blokuje workera | Concurrency=1 na kolejce `generation` jest OK (jedna instrukcja na raz z definicji). Jeśli zablokuje też inne kolejki → osobny worker process dla `generation` |
| Claude CLI rate limit na subskrypcji | Spike pokazał że 3 rewizje × Sonnet są OK. Przy demo dla dwóch użytkowników naraz może dojść limit → reject drugiej instrukcji z retry-after, nie równoległość |
| Workspace path w DB absolutne → migrowalność | W DB trzymamy **relatywne** (np. `storage/workspaces/123`), absolutizujemy w jobie przez `Rails.root.join`. Przy restoragu/zmianie hosta reset workspace_path, workspace recreate jest dopuszczalny (wszystko w git) |
| `rails new` w subprocess nadpisuje `.ruby-version` generatora | `rails_new` wywoływany z `chdir: workspace_root`, a sama komenda tworzy podkatalog. Generator ma `.ruby-version` w roocie, workspace też dostaje swoje. Ale **UWAGA**: sprawdzić czy `bundle` w workspace nie używa frum shima generatora — `VerifyRevision.with_clean_bundler_env` powinno to załatwić (zweryfikowane w spike) |

## Otwarte pytania (do decyzji w trakcie)

1. **`CreatePlan::AdHocLLM` implementacja**: czy LLM call w service używa RubyLLM z `response_format: json_schema` (deterministyczny output) czy drugi tool use? Decyzja w Kroku 4. Schema vs. tool to compromise między deterministycznym parsingiem a łatwością multi-step reasoning
2. **Workspace per projekt vs shared?** Per projekt (`storage/workspaces/<id>`). Shared bundle cache (`~/.bundle`) żeby nie reinstalować gemów przy każdym `rails new` — do optymalizacji w Kroku 5 jeśli wall time Krok 7 przekroczy limit
3. **Process supervisor dla subprocess Roast?** Start: plain `system()`. Jeśli okaże się że potrzebujemy timeoutu + kill + PID tracking — minimum `Process.spawn` + wątek watchdog. Pełny supervisor (np. Dragonfly) dopiero gdy Faza 2.5 (cancel) ruszy
4. **Czy RubyLLM chat dostaje kontekst o `Project.revisions`?** Happy-path mówi tak. W Fazie 2 PoC: tak, przez `chat.with_instructions(...)` ustawiane w `ChatRespondJob` każdorazowo (nie w `Chat.create!`) żeby odświeżać stan. Format: short markdown summary z listą revision summaries + statusów (summaries OK — to user-facing; detailed prompts dalej nie są pokazywane chatowi)
5. **Jakiego modelu użyć w `CreatePlan::AdHocLLM`?** Sonnet/Haiku? Sonnet daje lepsze plany, Haiku tani/szybki. Eksperyment w Kroku 4. Architektura swap-owalna (A6) pozwala na łatwy test obu

## Oszacowanie

- Krok 1 — 0.5 dnia
- Krok 2 — 0.5 dnia
- Krok 3 — 0.5 dnia
- Krok 4 — 1 dzień
- Krok 5 — 1.5-2 dni
- Krok 6 — 0.5 dnia
- Krok 7 — 0.5 dnia

Razem: **5-6 dni fokusa**. Realny kalendarz pewnie 1.5-2 tygodnie przy przerywaniu.

## Alternatywy (do potencjalnego powrotu)

Każda decyzja z sekcji "Decyzje architektoniczne" na górze jest odwracalna. Tabela sygnalizuje kiedy warto wrócić do alternatywy. Pełne rozumowanie za tymi wyborami — w historii git (commit rozpisania planu, 2026-04-16).

| # | Wybrane | Alternatywa | Wrócić gdy |
|---|---------|-------------|------------|
| A1 | Subprocess `bin/roast` | Native Ruby embedding (`require "roast"` in-process) | Startup subprocessa staje się znaczącym % czasu rewizji, albo chcemy live Turbo Stream z workflow bez subprocess pipe |
| A2 | Claude CLI (subskrypcja) | RubyLLM + własne toole (WriteFile/RunBash/ReadFile) w jednym procesie | Subskrypcja przestaje pokrywać koszt, albo chcemy dać userom własne klucze Anthropic/OpenRouter |
| A3 | Roast jako orchestrator | Plain Ruby job (`build_prompt → cli → verify → remediation → commit`) | Roast DSL przeszkadza bardziej niż pomaga (3 gotchas ze spike'a to już sygnał), albo pojawiają się wymagania poza jego zasięgiem (real-time streaming, branching) |
| A4 | Lokalny FS `storage/workspaces/<id>/` | `Dir.mktmpdir` per instruction, albo Docker container per projekt | Wychodzimy poza dev-only (multi-user → izolacja konieczna), albo testujemy generator w CI (tmpdir) |
| A5 | Jeden `ExecuteInstructionJob` z pętlą rewizji | `ExecuteRevisionJob` chainowany per rewizja (lepsza observability, retry granularny) | Chcemy retry pojedynczej failed rewizji bez odpalania całej Instruction |
| A6 | `CreatePlan::AdHocLLM` za abstrakcją `CreatePlan` | `CreatePlan::Archetypes` (template'y + slot-filling), albo hybrid | Jakość planów ad-hoc okaże się zmienna (logi z 5-10 runów), content workstream archetypów ruszy, albo znajdziemy tani-ale-dobry model (Haiku? GPT-4.1 mini?) |
| A7 | Lightweight tool `StartGeneration(intent, clarifications)` | `CreateInstruction(description, revisions: [...])` z detailed planem w tool args, albo `response_format: json_schema` | Tool reliability okaże się problemem — LLM nie woła `StartGeneration` w spodziewanym momencie. Fallback: UI button "Zacznij generować" wymusza tool call |

## Wyjścia z Fazy 2

Po domknięciu:

- **Dalej po warstwę preview** (Faza 3) — `02-phase-3-preview-isolation.md` z Kamal+Docker, osobny plan
- **Albo polish PoC dla demo** — lepszy UI, cancel, kilka archetypów, żeby pokazać na Tropical/Rails World jako demo
- **Albo monetyzacja / sponsorship** — token costs liczone, teraz mamy dane do rozmowy z Anthropic local ambassadors

Decyzję odłożyć do momentu gdy Faza 2 zamknie się. Na dziś: Faza 2 jest niezależna od każdego z tych kierunków.
