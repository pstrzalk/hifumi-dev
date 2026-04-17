# Happy Path — User Story (v4)

Pełna ścieżka użytkownika od otwarcia strony do działającej aplikacji.

## Zasady architektoniczne

- **Chat jest jedynym interfejsem** — nie ma osobnych pól, formularzy, statusów projektu. Wszystko dzieje się w konwersacji.
- **Wszystko jest wersjonowane** — wersja A + instrukcja X = wersja B. Każda zmiana to git commit.
- **RubyLLM jako fundament** — warstwa konwersacji zbudowana na RubyLLM, z narzędziami (tools) jako mechanizmem sterowania.
- **Chat = concierge intencji** — LLM chatu zbiera intencje od usera i przekazuje je do warstwy generacji przez tool call. Nie generuje planu implementacji, nie zna pełnej struktury wygenerowanej aplikacji, nie widzi detailed prompts. Prompt engineering planu żyje w service `CreatePlan`; szczegóły implementacji w workspace (git repo). Chat widzi tylko user-facing summaries rewizji (git commit messages).
- **Tool calls sterują procesem** — LLM decyduje o generowaniu, anulowaniu, sugerowaniu kolejnych kroków przez tool calls. Przyciski w UI to safety net, nie primary flow.
- **Suggested prompts prowadzą użytkownika** — system proponuje kolejne kroki jako edytowalne prompty. User nie musi wiedzieć co powiedzieć.
- **Dwa niezależne timeline'y** — chat biegnie ciągle, rewizje powstają w pewnych punktach. Synchronizowane przez anchor.
- **Liniowa historia** — zawsze do przodu. Undo = git revert. Architektura wspiera przyszły rewind, ale nie implementujemy.
- **Research → Plan → Implement → Verify** — każda Instruction przechodzi przez te fazy. Nie skaczemy do kodu bez zrozumienia kontekstu. Nie commitujemy kodu który nie przechodzi weryfikacji. Wzorowane na [Visuality AI coding workflow](https://www.visuality.pl/posts/from-vibes-to-process-ai-coding-in-production-codebases).

---

## RubyLLM Tools — mechanizm sterowania

LLM ma dostęp do narzędzi. To jest jedyny sposób na triggerowanie akcji w systemie. UI buttons to aliasy do tego samego.

### Narzędzia

```ruby
# Startuje generowanie. Przekazuje INTENCJĘ, nie plan.
class StartGeneration < RubyLLM::Tool
  param :intent, type: :string, desc: "Plain language: co user chce zbudować"
  param :clarifications, type: :object, desc: "Odpowiedzi na doprecyzowujące pytania (key/value)"
  # LLM wywołuje gdy user jest gotowy. NIE wymyśla planu — tool handler deleguje do CreatePlan service,
  # który generuje rewizje (detailed prompts) wewnątrz własnego system promptu. Chat LLM nie zna
  # wygenerowanego planu — dostaje tylko confirmation (instruction_id, revision_count).
end

# Anuluje bieżącą instrukcję.
class CancelInstruction < RubyLLM::Tool
  # LLM wywołuje gdy user pisze "stop" / "zmień podejście"
end

# Proponuje użytkownikowi co dalej. UI renderuje jako klikalne/edytowalne karty.
class SuggestPrompts < RubyLLM::Tool
  param :prompts, type: :array, desc: "Lista sugerowanych promptów z opcjonalnymi lukami do wypełnienia"
  # LLM wywołuje po zakończeniu generowania, po odpowiedzi na pytanie, albo gdy user nie wie co dalej
end

# Cofa ostatnią zmianę (git revert jako nowa rewizja).
class UndoLastChange < RubyLLM::Tool
  # LLM wywołuje gdy user pisze "cofnij"
end
```

### Warstwa `CreatePlan` — osobny service, nie tool

Tool `StartGeneration` jest lightweight — tylko przekazuje intent do service `CreatePlan`. Service żyje poza chatem, ma własny system prompt (reguły "Rails Way, 3-6 kroków, Tailwind, Hotwire, Devise..." — secret sauce projektu), i generuje listę rewizji z detailed prompts do Claude CLI.

```ruby
module CreatePlan
  # Interface: zwraca tablicę { summary:, prompt: } gotową do Revision.create!
  def self.call(intent:, clarifications: {}, context: {})
    implementation.call(intent: intent, clarifications: clarifications, context: context)
  end

  def self.implementation
    @implementation ||= AdHocLLM  # W przyszłości: Archetypes, Hybrid, CheapButGood
  end

  class AdHocLLM
    # LLM call z dedykowanym system promptem (secret sauce).
    # NIE jest to widoczne dla chat LLM ani dla usera.
  end
end
```

Dlaczego osobno: jakość planów = klucz do jakości generatora. Swap'owalne implementacje (archetype, hybrid, tańszy-ale-dobry model) to osobny workstream. System prompt plannera jest w 100% pod naszą kontrolą, nie zmieszany z system promptem chatu. Decyzje D1/D3 z `../02-architecture/01-workflows-and-decisions.md` żyją tutaj.

### Kontekst dla LLM

Przy każdym `chat.ask(...)` LLM dostaje w kontekście:
- Historię konwersacji (RubyLLM robi to automatycznie)
- **Status bieżącej instrukcji** (jeśli jest aktywna): która rewizja się generuje, ile gotowych, ile zostało
- **Listę rewizji** projektu — **tylko `summary` + `status`**, czyli user-facing wersja tego co się dzieje (summaries to git commit messages, zrozumiałe dla usera)
- Dostępne narzędzia

Co LLM **nie dostaje** (wprost wynika z zasady "chat = concierge intencji"):
- Detailed prompts rewizji (`Revision.prompt`) — one idą tylko do Claude CLI przez workflow Roast
- Tree plików wygenerowanej apki, schema modeli, zawartość kontrolerów
- Outputów Claude CLI, logów weryfikacji, stack traces (failure payload jest sumaryzowany do user-facing opisu przed wejściem do kontekstu)
- System promptu `CreatePlan` ani generated plan przed startem rewizji

Dzięki temu LLM może reagować na to co user widzi: "widzę że krok 3 się nie powiódł, spróbuję innego podejścia" albo "generowanie zakończone, proponuję następne kroki." Ale nie zaczyna rozmowy o architekturze kontrolerów ani nie pisze "dodałem metodę X w klasie Y" — bo tego nie wie.

### Flow

```
User message
    ↓
RubyLLM chat.ask(message, tools: [...], context: generation_status)
    ↓
LLM odpowiada tekstem + opcjonalnie tool calls
    ↓
    ├── tekst → Message w chacie → Turbo Stream
    ├── StartGeneration → CreatePlan service → Instruction + Revisions → orkiestracja
    ├── CancelInstruction → anuluje bieżącą → git reset
    ├── SuggestPrompts → renderuje karty w UI → user klika/edytuje
    └── UndoLastChange → git revert jako nowa rewizja
```

---

## Suggested Prompts — prowadzenie użytkownika

Użytkownik nie musi wiedzieć co powiedzieć. System proponuje.

### Jak wyglądają

Po zakończeniu generowania:
> *Aplikacja gotowa! Co dalej?*
> - [Dodaj autentykację — klienci logują się przez email i hasło]
> - [Dodaj panel admina do zarządzania ___]
> - [Zmień kolorystykę na ___]

Każda sugestia to klikalna karta z tekstem. Tekst może mieć luki (`___`) które user wypełnia. Klik → tekst trafia do pola input → user może edytować → wysyła.

### Kiedy się pojawiają

LLM wywołuje `SuggestPrompts` w naturalnych momentach:
- Po pierwszej wiadomości (guided): sugestie kierunku (np. *"system rezerwacji z kalendarzem"*, *"sklep z produktami cyfrowymi"*)
- **Po zakończeniu generowania**: co dodać dalej
- Po odpowiedzi na pytanie: "Czy chcesz też..."
- Gdy user pisze coś niejasnego: sugestie uściślające

Sugestie **nie obejmują** zatwierdzenia planu przed startem — user nie widzi planu. Po zebraniu intencji LLM po prostu wywołuje `StartGeneration`, generowanie rusza, user widzi postęp.

### Nie są obowiązkowe

User zawsze może zignorować sugestie i napisać cokolwiek. Sugestie to pomoc, nie ograniczenie.

---

## Research → Plan → Implement → Verify

Każda Instruction przechodzi przez te fazy. Wzorowane na [Visuality AI coding workflow](https://www.visuality.pl/posts/from-vibes-to-process-ai-coding-in-production-codebases). Verify jest tym co odróżnia nas od vibe coding — nie commitujemy kodu który nie przechodzi weryfikacji.

Kluczowa zasada: **środek ciężkości researchu przesuwamy w stronę gotowej wiedzy**, ale nie eliminujemy eksploracji. Archetype i app manifest to punkt startowy — pozwalają szybko wejść w kontekst. Głębszy research dzieje się gdy jest potrzebny (nowa domena, nowe rozwiązania, nieoczywisty problem).

### Dwa źródła gotowej wiedzy

**1. Baza archetypów (nowe apki)**

Wewnętrzna baza wiedzy o typach aplikacji. Nasz core IP.

- "E-commerce z dostawą" → pattern: Product, Cart, Order, Delivery, Payment. Devise dla klientów, Avo admin, Stripe.
- "System rezerwacji" → pattern: Resource, Slot, Booking, Calendar. Availability logic, reminders.
- "SaaS z subskrypcjami" → pattern: Account, Plan, Subscription, Billing. Multi-user, Pay gem.
- "Blog/CMS" → pattern: Post, Category, Tag, Author. Action Text, SEO.

Archetype to nie template — to zestaw wiedzy o domenie + rekomendacje techniczne. Punkt startowy, nie gotowa odpowiedź. Apka "sklep z kwiatami z dostawą tego samego dnia" może pasować do archetypu e-commerce, ale "tego samego dnia" wymaga dodatkowego researchu (logistyka, sloty czasowe, ograniczenia geograficzne).

Baza rośnie z czasem — każda nowa apka uczy nas nowych patternów.

**2. App manifest (istniejące apki)**

Każda wygenerowana apka utrzymuje dokumentację o sobie. Aktualizowana po każdej rewizji.

```
docs/
  architecture.md    — modele, relacje, kluczowe kontrolery, routing
  conventions.md     — podjęte decyzje, użyte gemy, wzorce
  domain.md          — słownik domeny, reguły biznesowe
```

Manifest pozwala szybko wejść w kontekst bez skanowania codebase'u. Ale nie eliminuje potrzeby researchu — "dodaj system rabatowy" wymaga zbadania jak rabaty mają współgrać z istniejącym modelem zamówień, jakie gemy mogą pomóc, jakie edge case'y są do rozwiązania.

Po każdej rewizji: **krok "update docs"** aktualizuje manifest. Część procesu implementacji.

### Cykl per Instruction

Instrukcje wykonywane przez zdefiniowane workflow'y (patrz `../02-architecture/01-workflows-and-decisions.md`).

**Nowa apka → Workflow W1:**

| Krok | Typ | Co się dzieje |
|------|-----|---------------|
| W1.1 | deterministic | Załaduj archetype |
| W1.2 | LLM (decyzja D1) | Research domeny — jeśli archetype nie pokrywa wymagań |
| W1.3 | LLM | Wygeneruj plan |
| W1.4 | deterministic | Utwórz rekordy Revision |
| W1.5 | loop → W2 | Wykonaj rewizje |
| W1.6-7 | deterministic | Zamknij instrukcję, uruchom preview |

**Iteracja → Workflow W4:**

| Krok | Typ | Co się dzieje |
|------|-----|---------------|
| W4.1 | deterministic | Załaduj app manifest |
| W4.2 | LLM (decyzja D3) | Research — manifest wystarczy / szukaj nowych rozwiązań / czytaj kod |
| W4.3 | LLM | Wygeneruj plan |
| W4.4 | loop → W2 | Wykonaj rewizje |
| W4.5-6 | deterministic | Zamknij instrukcję, restart preview |

Decyzje non-deterministyczne (D1, D3) to jawnie opisane punkty w workflow'ach — nie "agent sam ocenia" ale "krok W4.2 z opcjami [a] manifest wystarczy [b] szukaj rozwiązań [c] czytaj kod."

### Verification + remediation (safeguard)

Po każdej rewizji (W2.4) uruchamiana jest weryfikacja: bundle check, migracje, herb lint, boot check, testy. Jeśli coś nie przechodzi:

1. **Remediation loop** (max 2 próby): błędy wracają do Claude CLI → agent naprawia → re-verify
2. Jeśli po 2 próbach dalej fail → W2.F1: oznacz rewizję jako failed z pełnym logiem błędów
3. W2.F2: git reset do parent revision
4. W2.F3: raportuj do warstwy konwersacji → agent (decyzja D6) reaguje w chacie, ma kontekst co dokładnie failowało

Kluczowe: **nie commitujemy kodu który nie bootuje.** Git historia zawiera tylko działające rewizje.

### Manual checkpoints (safeguard, guided mode)

Między większymi rewizjami agent może zapauzować i poprosić o review:
> *Modele gotowe. Zanim przejdę do widoków — chcesz sprawdzić strukturę?*

W quick mode — bez checkpoint'ów, pełna automatyka.

---

## Model danych

```ruby
Project
  - name: string
  - workspace_path: string
  has_one :chat
  has_many :instructions
  has_many :revisions

Chat (RubyLLM)
  belongs_to :project
  has_many :messages

Message (RubyLLM)
  belongs_to :chat
  - role: enum (user, assistant, tool)
  - content: text
  # tool call messages zawierają wywołania narzędzi i ich wyniki

Instruction
  belongs_to :project
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions
  - phase: enum (researching, planning, implementing, completed, failed, cancelled)
  - description: text
  - research_output: text   # wynik fazy research (kontekst dla planu i implementacji)

Revision
  belongs_to :project
  belongs_to :instruction
  belongs_to :parent, class_name: "Revision", optional: true
  - git_sha: string
  - summary: text
  - position: integer
  - status: enum (pending, generating, completed, failed)
```

### Kluczowe decyzje

**Instruction powstaje z tool call** — nie z logiki aplikacji. LLM wywołuje `StartGeneration(intent, clarifications)`, tool handler deleguje do `CreatePlan` service który generuje rewizje, potem tworzy rekord `Instruction` + N × `Revision`. Anchor = wiadomość z tool callem.

**Cancel z tool call** — LLM interpretuje "stop" i wywołuje `CancelInstruction`. Przycisk "Cancel" w UI robi to samo (tworzy system message + wywołuje ten sam handler).

**SuggestPrompts to tool call, nie osobny model** — sugestie renderowane z tool result message. Nie potrzebują własnej tabeli.

**UI buttons = aliasy** — przycisk "Cancel" w UI tworzy message (role: user, content: "[cancel requested]") i odpala `CancelInstruction` handler. Efekt identyczny jak gdyby user napisał "stop" a LLM wywołał tool.

### Dwa timeline'y

```
Chat:       msg1 → msg2 → msg3(tool:start) → msg4 → msg5 → msg6(tool:suggest) → msg7 → msg8(tool:start)
                              |                                                              |
                            anchor                                                         anchor
                              |                                                              |
Instruction:               instr1                                                         instr2
                              |                                                              |
Revisions:     rev1 → rev2 → rev3                                                         rev4

- msg3 to tool call StartGeneration — anchor na tym punkcie. CreatePlan service tworzy rev1-rev3.
- msg4-msg5 to rozmowa PODCZAS generowania
- msg6 to tool call SuggestPrompts po zakończeniu — user widzi sugestie
- msg7 to user klikający sugestię (lub piszący własne)
- msg8 to tool call StartGeneration z nową instrukcją — CreatePlan tworzy rev4
```

---

## Krok 1: Nowy projekt

### Co widzi użytkownik
Pole tekstowe. Przykłady promptów jako inspiracja. Dwa przyciski: "Quick" / "Guided".

### Co robi użytkownik
Wpisuje: *"Aplikacja do sprzedaży i dostawy kwiatów..."*

### Serwer (synchronicznie)
1. `Project.create!`, `Chat.create!`, `Message.create!(role: :user)`
2. `git init` w workspace
3. Redirect → `/projects/{id}`
4. `ChatRespondJob.perform_later` — LLM przetwarza pierwszą wiadomość

---

## Krok 2: Konwersacja (guided path)

### Co widzi użytkownik
Chat. System odpowiada pytaniami + sugestiami:

> *Kilka pytań:*
> 1. *Panel admina osobno czy wspólny interfejs?*
> 2. *Śledzenie dostaw czy prosty status?*
>
> [Osobny panel admina, pełne śledzenie dostaw]
> [Wspólny interfejs, prosty status zamówienia]
> [___]

Sugestie to gotowe odpowiedzi — klik i wysyłka. Albo user pisze własne.

### Serwer
1. `Message.create!(role: :user)`
2. `ChatRespondJob`:
   - `chat.ask(...)` z tools + generation context
   - LLM odpowiada tekstem + `SuggestPrompts` tool call
   - Tekst → Message → Turbo Stream
   - Sugestie → renderowane jako karty pod wiadomością

### Quick path
LLM od razu wywołuje `StartGeneration(intent, clarifications: {})` bez pytań doprecyzowujących.

---

## Krok 3: Start generowania

Nie ma "pokaż plan, user zatwierdza". Po zebraniu intencji LLM wywołuje `StartGeneration` i generowanie rusza. User widzi postęp, nie plan.

### Co widzi użytkownik
Krótka wiadomość od LLM + lista rewizji w toku pojawiająca się obok/pod chatem:

> *OK, rozumiem. Zaczynam budować — zobaczysz postęp poniżej.*
>
> ⏳ Revision 1: "Rails scaffolding + Tailwind" — *generating*
> ⚪ Revision 2: "Modele domenowe (Product, Order, Delivery)" — *pending*
> ⚪ Revision 3: "Panel klienta" — *pending*
> ⚪ Revision 4: "Panel florystki" — *pending*
> ⚪ Revision 5: "Devise auth + role" — *pending*

User widzi **tylko summaries rewizji** (user-facing, git commit-like). Detailed prompts (`Revision.prompt`) żyją w DB i idą do Claude CLI, ale **nigdy nie trafiają do UI ani chatu**.

### Serwer
1. LLM wywołuje `StartGeneration(intent: "sklep z kwiatami z dostawą tego samego dnia", clarifications: {admin_panel: "osobny", delivery_tracking: "pełne"})`
2. Tool handler:
   - `CreatePlan.call(intent, clarifications)` — service generuje rewizje z own system promptem (secret sauce)
   - `Instruction.create!(anchor_message: msg, phase: :processing)`
   - `Revision.create!` per wygenerowana rewizja, status: `pending`
3. Tool zwraca do LLM **tylko confirmation**: `{instruction_id, revision_count: 5, intent}`. LLM nie dostaje treści `Revision.prompt`.
4. Event `instruction.requested` → Solid Queue triggeruje workflow W1 (od kroku W1.5 — pętla po rewizjach)

### Gdzie żyje "plan"
- **Intencja + clarifications** — w argumentach tool call, widoczne w chacie
- **Summaries rewizji** — user-facing, w DB (`Revision.summary`), w UI, w kontekście chatu po fakcie ich utworzenia
- **Detailed prompts** — w DB (`Revision.prompt`), czytane przez Roast workflow, nigdzie indziej

---

## Krok 4: Generowanie

### Co widzi użytkownik
Chat otwarty. Postęp w chacie lub panelu obok:

> ⏳ *Generuję (krok 2/6: Modele domenowe)...*

User może pisać, pytać, komentować. Może napisać *"stop"* → LLM wywołuje `CancelInstruction`.

### Serwer — orkiestracja

**`GenerationOrchestrator`** — sekwencyjnie przetwarza `pending` rewizje.

**`ExecuteRevisionJob`**:
1. `revision.update!(status: :generating)` → Turbo Stream
2. Prompt + kontekst (plan + app manifest + revision notes z poprzedniej rewizji) → `claude -p "..." --cwd workspace/...`
3. Stream output → Turbo Stream (throttled)
4. **Verify**: `bundle check` → `rails db:prepare` → `herb lint` → `rails runner "puts :ok"` → `rails test`
5. Jeśli verify fail → **remediation loop** (błędy → Claude CLI → re-verify, max 2 próby)
6. `git commit` → update app manifest + revision notes → `revision.update!(status: :completed, git_sha: sha)`
7. Następna rewizja

**Po zakończeniu wszystkich rewizji:**
- `instruction.update!(status: :completed)`
- Status generowania idzie do kontekstu LLM
- LLM automatycznie reaguje: `SuggestPrompts` z propozycjami co dalej
- Preview startuje (krok 5)

**Failure:**
- `revision.update!(status: :failed)`, stop
- Status idzie do kontekstu LLM → LLM reaguje w chacie (proponuje retry / zmianę podejścia)

**Cancel:**
- `CancelInstruction` tool → `instruction.cancelled!`
- `git reset --hard` do ostatniej completed rewizji
- LLM reaguje: *"Zatrzymano. Co dalej?"* + `SuggestPrompts`

### Git jako checkpointing
- `git commit` po każdej rewizji
- Rollback = `git reset --hard {parent.git_sha}`

### CLI
```bash
bin/generate execute --project-id=123 --revision-id=456
```

---

## Krok 5: Preview

### Co widzi użytkownik
Split view: chat + iframe z działającą aplikacją.
Pod chatem: sugestie co dalej.

### Serwer
`StartPreviewJob` (auto po ostatniej rewizji):
1. `bundle install` (shared cache) → `rails db:prepare` → `rails server -p {port}`
2. `{project_id}.preview.domain.com` → reverse proxy → `localhost:{port}`

### Potencjalne problemy
- **Izolacja** — limit aktywnych preview na start, kontenery w przyszłości
- **Bezpieczeństwo** — trusted users na start
- **Seed data** — LLM generuje seeds. Pusty preview = zły UX

---

## Krok 6: Iteracja

### Co widzi użytkownik
Chat obok preview. Pisze własne albo klika sugestię:

> [Dodaj zdjęcia do bukietów]
> [Dodaj system rabatowy / kodów promocyjnych]
> [Skonfiguruj maile potwierdzające zamówienie]

### Serwer
1. User message → `ChatRespondJob`
2. LLM analizuje request → wywołuje `StartGeneration(intent, clarifications)`. Czy to będzie 1 rewizja czy 5 — decyzja `CreatePlan` service, nie chat LLM
3. Generowanie → git commit → preview restart
4. LLM wywołuje `SuggestPrompts` po zakończeniu

### Undo
- User: *"Cofnij"* → LLM wywołuje `UndoLastChange` → `git revert` jako nowa rewizja

---

## Krok 7: Export

Akcje w UI (nie przez chat):
- **Download ZIP**
- **Push to GitHub** — OAuth → repo → push
- (Przyszłość) **Deploy** — Kamal

---

## Architektura

```
┌───────────────────────────────────────────────────────┐
│                     WEB UI (Rails)                    │
│           Turbo Frames + Streams + Stimulus           │
├──────────────────────┬────────────────────────────────┤
│    Chat              │    Preview (iframe)            │
│    - always open     │    → {id}.preview.domain.com   │
│    - suggested       │                                │
│      prompts as      │                                │
│      clickable cards │                                │
│    Revision timeline │                                │
└──────────┬───────────┴──────────┬─────────────────────┘
           │                      │
           ▼                      ▼
┌───────────────────────────────────────────────────────┐
│                   RAILS BACKEND                       │
│                                                       │
│  Project ──has_one──→ Chat (RubyLLM)                  │
│     │                   ├── Messages                  │
│     │                   └── Tools:                    │
│     │                       StartGeneration           │
│     │                       CancelInstruction         │
│     │                       SuggestPrompts            │
│     │                       UndoLastChange            │
│     ├──has_many──→ Instructions                       │
│     │                   ├── anchor_message             │
│     │                   └── max 1 active              │
│     └──has_many──→ Revisions                          │
│                         └── linear chain              │
│                                                       │
├───────────────────────────────────────────────────────┤
│  Solid Queue                                          │
│  ChatRespondJob │ ExecuteRevisionJob │ PreviewJob     │
├───────────────────────────────────────────────────────┤
│  Solid Cable → Turbo Streams                          │
└──────────────────────┬────────────────────────────────┘
                       │
        ┌──────────────┴──────────────┐
        ▼                             ▼
┌───────────────────┐   ┌──────────────────────────────┐
│    RubyLLM        │   │   Generation Engine          │
│    (conversation  │   │   Claude CLI (start)         │
│     + tools)      │   │   RubyLLM+tools (future)     │
└───────────────────┘   └──────────┬───────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────┐
                        │   Workspace (filesystem)     │
                        │   workspace/projects/{id}/   │
                        │   └── git repo (linear)      │
                        └──────────────────────────────┘
```

---

## Krytyczne ryzyka

1. **Czas generowania** — minuty, remediation loop może wydłużyć. Mitigacja: live progress, async chat, suggested prompts (user planuje następny krok czekając).
2. **Jakość kodu** — mitigacja: verify step po każdej rewizji (bundle, migracje, herb, boot, testy) + remediation loop (max 2 próby naprawy). Git historia zawiera tylko zweryfikowane rewizje.
3. **Koszty** — tracking tokenów per Instruction. Remediation loop zwiększa koszt per rewizja (max 3x w worst case). Monitorujemy remediation rate jako sygnał jakości promptów.
4. **Kontekst między rewizjami** — revision notes (decyzje implementacyjne, nie summary) karmione do kolejnych rewizji. App manifest daje high-level, revision notes dają szczegóły.
5. **Tool call reliability** — LLM musi poprawnie wywoływać narzędzia. Mitigacja: dobrze opisane narzędzia, walidacja parametrów, fallback na UI buttons.
6. **Suggested prompts quality** — złe sugestie to gorszy UX niż brak sugestii. Mitigacja: dobre system prompty, kontekst o stanie projektu.

---

## Co zostawiamy na przyszłość

- **Rewind / branching** — architektura wspiera, nie implementujemy
- **Równoległe instrukcje** — jedna aktywna na raz
- **Hot reload preview** — pełny restart na start
- **Deployment** — Kamal / in-house, osobny workstream
- **Dodatkowe tools** — np. `BrowsePreview` (LLM "widzi" wygenerowaną apkę), `ShowDiff`

---

## CLI do testowania

```bash
bin/generate respond   --project-id=123                  # odpowiedź chatu z tools
bin/generate plan      --project-id=123                  # generowanie planu
bin/generate execute   --project-id=123 --revision-id=1  # jedna rewizja (implement + verify)
bin/generate verify    --project-id=123                  # standalone verify (debug/dev)
bin/generate cancel    --project-id=123                  # cancel
bin/generate preview   --project-id=123                  # start preview
bin/generate full      --prompt "Sklep z kwiatami..."    # full pipeline
```
