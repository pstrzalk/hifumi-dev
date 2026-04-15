# Integracja warstw

Jak RubyLLM, Roast i Solid Queue komunikują się ze sobą.

## Zasada

Warstwy nie importują się nawzajem. Komunikacja przez eventy na granicach. Faza 1 używa `ActiveSupport::Notifications` jako lekkiego event busa. Faza 2 może podmienić na dowolny pub/sub bez zmiany workflow'ów ani chatu.

## Schemat

```
RubyLLM (chat)                    Roast (workflows)
     │                                  │
     │  tool call                       │  workflow step
     ▼                                  ▼
┌──────────┐                     ┌──────────────┐
│ Publish:  │                     │ Publish:      │
│ instruction│                    │ revision      │
│ .requested│                     │ .completed    │
└─────┬─────┘                     └──────┬───────┘
      │                                  │
      ▼                                  ▼
┌─────────────────────────────────────────────────┐
│  ActiveSupport::Notifications (event bus)        │
│  Faza 1: in-process, synchronous subscribers     │
│  Faza 2: wymienialny na pub/sub, message queue   │
└─────────────────────────────────────────────────┘
      │                                  │
      ▼                                  ▼
┌──────────┐                     ┌──────────────┐
│ Subscribe:│                     │ Subscribe:    │
│ enqueue   │                     │ enqueue       │
│ Roast job │                     │ follow-up job │
└──────────┘                     └──────────────┘
```

## Eventy — faza 1

```ruby
# Emitowane przez warstwę konwersacji (RubyLLM tool handlers)
"instruction.requested"    # user chce generować → payload: { instruction_id: }
"instruction.cancelled"    # user chce anulować  → payload: { instruction_id: }
"undo.requested"           # user chce cofnąć    → payload: { project_id: }

# Emitowane przez warstwę wykonania (Roast workflows)
"revision.started"         # rewizja się rozpoczęła   → payload: { revision_id: }
"revision.completed"       # rewizja zakończona       → payload: { revision_id:, git_sha: }
"revision.failed"          # rewizja się nie powiodła  → payload: { revision_id:, error: }
"instruction.completed"    # cała instrukcja gotowa    → payload: { instruction_id: }
"instruction.failed"       # instrukcja się nie powiodła → payload: { instruction_id: }
"preview.ready"            # preview wystartował       → payload: { project_id:, url: }
```

## Problem 1: Pętla zwrotna Roast → chat

Roast nie wie o chacie. Publikuje event. Subscriber enqueue'uje job.

```ruby
# Roast workflow — ostatni krok
ruby(:publish_completed) do
  ActiveSupport::Notifications.instrument("instruction.completed", instruction_id: instruction.id)
end

# Subscriber (config/initializers/event_subscribers.rb)
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  ChatFollowUpJob.perform_later(payload[:instruction_id])
end

# Job — jedyne miejsce gdzie warstwy się "dotykają"
class ChatFollowUpJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    # RubyLLM generuje follow-up w chacie
    project.chat.ask("Generation completed. Suggest next steps.", tools: [SuggestPrompts])
  end
end
```

Tak samo dla failure:
```ruby
ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
  ChatFollowUpJob.perform_later(payload[:instruction_id], event: :failed)
end
```

**Coupling: zero.** Roast emituje event. Subscriber to glue code. RubyLLM działa w jobie. Żadna warstwa nie importuje drugiej.

**Faza 2**: subscriber zamiast enqueue'ować job, publikuje do message queue. Job po drugiej stronie. Zero zmian w Roast i RubyLLM.

## Problem 2: Cancel mid-workflow

Cancel to flaga w bazie + event. Workflow sprawdza flagę między krokami.

```ruby
# RubyLLM tool handler
class CancelInstruction < RubyLLM::Tool
  def execute
    instruction = current_instruction
    instruction.update!(phase: :cancelled)
    ActiveSupport::Notifications.instrument("instruction.cancelled", instruction_id: instruction.id)
  end
end

# Subscriber
ActiveSupport::Notifications.subscribe("instruction.cancelled") do |*, payload|
  CancelWorkflowJob.perform_later(payload[:instruction_id])
end

# CancelWorkflowJob — zabija Claude CLI process jeśli biegnie
class CancelWorkflowJob < ApplicationJob
  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    # Kill running CLI process jeśli PID jest zapisany
    Process.kill("TERM", instruction.cli_pid) if instruction.cli_pid
    # Git reset do ostatniej completed rewizji
    GitService.reset_to_last_completed(instruction.project)
  end
end
```

Wewnątrz Roast workflow — check między krokami:
```ruby
# Helper wywoływany między krokami
ruby(:check_cancelled) do
  raise Cancelled if instruction.reload.cancelled?
end
```

**Faza 1**: flaga w bazie + SIGTERM na PID. Proste, działa.
**Faza 2**: event "instruction.cancelled" może być broadcastowany do runnera workflow'u w real-time (np. przez Action Cable wewnętrznie), bez pollowania bazy.

## Problem 3: Dwa klienty LLM

Faza 1: akceptujemy. Jasny podział:

| Klient | Warstwa | Wywołania |
|--------|---------|-----------|
| RubyLLM | Konwersacja | Chat z userem, tool calls, suggested prompts |
| Raix (Roast) | Workflow | Research, planning, update docs (kroki `chat()` w Roast) |
| Claude CLI | Workflow | Generowanie kodu (krok `agent()` w Roast) |

Wspólna konfiguracja:
```ruby
# config/initializers/llm.rb
# Oba czytają z tych samych ENV vars
RubyLLM.configure { |c| c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] }
# Raix/Roast konfiguruje się osobno ale z tego samego źródła
```

Tracking kosztów — jeden serwis, wiele źródeł:
```ruby
class CostTracker
  def self.record(source:, tokens:, model:, instruction_id:)
    # source: "rubyllm", "roast", "claude_cli"
    CostEntry.create!(source:, tokens:, model:, instruction_id:)
  end
end
```

**Faza 2**: jeśli chcemy ujednolicić — RubyLLM jako jedyny klient. Roast kroki `chat()` zastąpione custom krokami `ruby()` wywołującymi RubyLLM. Ale to optymalizacja, nie konieczność.

## Turbo Streams — broadcasting z workflow'ów

Roast workflow emituje eventy. Subscriber broadcastuje do UI.

```ruby
ActiveSupport::Notifications.subscribe("revision.started") do |*, payload|
  revision = Revision.find(payload[:revision_id])
  revision.broadcast_replace_to(revision.project, target: "revision_#{revision.id}")
end

ActiveSupport::Notifications.subscribe("revision.completed") do |*, payload|
  revision = Revision.find(payload[:revision_id])
  revision.broadcast_replace_to(revision.project, target: "revision_#{revision.id}")
end
```

Roast workflow nie wie o Turbo Streams. Publikuje event, ktoś inny broadcastuje.

## Wytyczne

### Subscribers: tylko enqueue lub broadcast

Subscriber `ActiveSupport::Notifications` **nigdy** nie wykonuje ciężkiej logiki. Robi jedną z dwóch rzeczy:
- `SomeJob.perform_later(...)` — zleca pracę do Solid Queue
- `broadcast_replace_to(...)` — broadcastuje Turbo Stream

Wszystko inne idzie do joba.

### HTTP request: tylko zapis + enqueue

Request HTTP nigdy nie czeka na LLM, Roast, ani Claude CLI. Cykl życia requestu:
1. Zapisz dane (Message, Instruction)
2. Enqueue job
3. Return

Cała praca dzieje się w Solid Queue workerach. Eventy emitowane są z workerów, nie z requestów.

### ActiveSupport::Notifications — synchroniczne, świadomie

Notifications działają synchronicznie w procesie który je emituje. To nie jest problem bo:
- Emitujemy z Solid Queue workerów, nie z HTTP requestów
- Subscribers robią tylko enqueue/broadcast (milisekundy)
- Ciężka praca idzie do osobnych jobów

W fazie 2 ten event bus może zostać zastąpiony asynchronicznym pub/sub (np. Solid Queue pub/sub, dedykowany broker). Interfejs eventów (nazwy, payloady) zostaje ten sam — zmienia się tylko transport.

## Flow-break ready

Dzięki eventom na granicach, w fazie 2 można wstawić flow-break na dowolnym etapie:

```
revision.completed → subscriber sprawdza: czy potrzebny manual checkpoint?
  [tak] → nie enqueue'uj następnej rewizji, czekaj na event od usera
  [nie] → kontynuuj normalnie
```

To jest seedy pub/sub architektury bez budowania pub/sub.
