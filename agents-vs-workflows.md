# Agenty vs Workflow'y

Rozgraniczenie: co jest agentem (decyzje LLM), co jest workflow'em (zdefiniowane kroki).

## Zasada

**Agent** = autonomiczne decyzje. LLM decyduje CO zrobić i KIEDY.
**Workflow** = zdefiniowana sekwencja kroków. Niektóre kroki używają LLM (non-deterministyczne), ale struktura jest z góry określona.

Minimalizujemy "agent sam ocenia." Zamiast tego: "workflow W1, krok 3 używa LLM do podjęcia decyzji D z opcjami [a, b, c]."

## Architektura: dwie warstwy

```
┌─────────────────────────────────────┐
│  WARSTWA KONWERSACJI (agent)        │
│  RubyLLM + tools                   │
│  Decyduje: co powiedzieć userowi,   │
│  kiedy triggerować workflow          │
│  → via tool calls                   │
└────────────┬────────────────────────┘
             │ tool call: CreateInstruction
             │ tool call: CancelInstruction
             │ tool call: SuggestPrompts
             ▼
┌─────────────────────────────────────┐
│  WARSTWA WYKONANIA (workflows)      │
│  Roast / własna orkiestracja        │
│  Zdefiniowane kroki, traceability,  │
│  session replay                     │
└─────────────────────────────────────┘
```

**Agent** (warstwa konwersacji) decyduje **CO** — "użytkownik chce dodać system rabatowy, trigeruję workflow generowania."

**Workflow** (warstwa wykonania) definiuje **JAK** — "krok 1: załaduj manifest, krok 2: research, krok 3: plan, krok 4-N: implementacja."

Tool calls to most między agentem a workflow'ami.

---

## Katalog workflow'ów

### W1: Generowanie nowej aplikacji

Triggerowany przez: tool call `CreateInstruction` z planem.

```
W1.1  [deterministic]  Załaduj archetype (dopasuj typ apki do bazy archetypów)
W1.2  [LLM]            Research domeny (jeśli archetype nie wystarcza)
        → Decyzja D1: czy archetype pokrywa wymagania?
          [a] tak → skip W1.2, przejdź do W1.3
          [b] nie → LLM analizuje domenę, generuje dodatkowy kontekst
W1.3  [LLM]            Wygeneruj plan (lista rewizji)
W1.4  [deterministic]  Utwórz rekordy Revision w bazie (pending)
W1.5  [loop]           Dla każdej rewizji → wywołaj W2 (Execution workflow)
W1.6  [deterministic]  Oznacz Instruction jako completed
W1.7  [deterministic]  Triggeruj W3 (Preview)
```

### W2: Wykonanie pojedynczej rewizji

Triggerowany przez: W1.5 lub W4.4 (iteracja).

Cykl per rewizja: **Implement → Verify → Commit**. Nie commitujemy kodu który nie przechodzi weryfikacji.

```
W2.1  [deterministic]  Oznacz rewizję jako generating
W2.2  [deterministic]  Zbuduj prompt:
        - opis kroku z planu
        - app manifest (docs/)
        - revision notes z poprzedniej rewizji (jeśli jest)
        - kontekst planu (co już zrobione, co zostało)
W2.3  [LLM/agent]      Wykonaj Claude CLI z promptem w cwd workspace'u
        → Agent (Claude Code) z ograniczonym scope: opis kroku + cwd.
W2.4  [deterministic]  Weryfikacja — sekwencja checków:
        a) bundle check              — dependencies się resolvują
        b) rails db:prepare          — migracje przechodzą
        c) herb lint app/views/      — ERB/HTML poprawne
        d) rails runner "puts :ok"   — aplikacja bootuje
        e) rails test (jeśli testy istnieją) — testy przechodzą
        → Jeśli wszystkie pass → W2.5
        → Jeśli fail → W2.R (remediation loop)
W2.5  [deterministic]  Git add + commit (annotated: co i dlaczego)
W2.6  [LLM]            Zaktualizuj app manifest (docs/) + revision notes
        → Decyzja D2: co zmieniło się w architecture/conventions/domain?
          LLM generuje diff do docs, nie pisze od zera.
        → Revision notes: zapis decyzji implementacyjnych tej rewizji.
          Nie summary ("dodano modele") ale kontekst ("Flower ma STI bo
          seasonal/permanent to różne reguły walidacji, nie osobne tabele").
          Karmione do W2.2 następnej rewizji.
W2.7  [deterministic]  Oznacz rewizję jako completed, zapisz git_sha
W2.8  [deterministic]  Wypchnij status przez Turbo Stream
```

#### W2.R: Remediation loop (max 2 próby)

Weryfikacja nie przeszła — oddajemy błędy agentowi do naprawy zamiast od razu failować.

```
W2.R1 [deterministic]  Zbierz output z nieudanych checków (error messages, stack traces)
W2.R2 [LLM/agent]      Claude CLI: napraw problemy
        → Prompt: "Weryfikacja nie przeszła. Oto błędy: {errors}. Napraw."
        → Ten sam workspace, ten sam cwd. Agent widzi swój wcześniejszy kod.
W2.R3 [deterministic]  Re-run weryfikacji (W2.4 a-e)
        → pass → kontynuuj do W2.5
        → fail i retry_count < 2 → W2.R1
        → fail i retry_count >= 2 → W2.F1 (failure path)
```

Dlaczego max 2: trzecia próba naprawy tego samego błędu to już "agent nie umie tego zrobić", nie "drobny fix." Eskalujemy do usera.

#### Failure path

```
W2.F1 [deterministic]  Oznacz rewizję jako failed, zapisz ostatnie błędy weryfikacji
W2.F2 [deterministic]  Git reset --hard do parent revision
W2.F3 [deterministic]  Raportuj failure do warstwy konwersacji
        → Payload zawiera: co failowało (który check), błędy, ile prób
        → Agent (chat) decyduje jak zareagować (D6): zmiana podejścia, pytanie do usera
```

### W3: Preview

Triggerowany przez: zakończenie W1 lub W4.

```
W3.1  [deterministic]  Zatrzymaj istniejący preview (jeśli jest)
W3.2  [deterministic]  bundle install (shared cache)
W3.3  [deterministic]  rails db:prepare
W3.4  [deterministic]  rails server -p {port}
W3.5  [deterministic]  Zweryfikuj że serwer odpowiada (health check)
W3.6  [deterministic]  Wypchnij preview URL przez Turbo Stream
```

W3 jest **w pełni deterministyczny**. Żadnych decyzji LLM.

### W4: Iteracja (zmiana w istniejącej apce)

Triggerowany przez: tool call `CreateInstruction` (iteracja).

```
W4.1  [deterministic]  Załaduj app manifest (docs/)
W4.2  [LLM]            Research (jeśli potrzebny)
        → Decyzja D3: czy manifest + request usera wystarczą do planu?
          [a] proste (dodaj pole, zmień kolor) → skip, przejdź do W4.3
          [b] wymaga nowych rozwiązań → LLM szuka gemów, bada opcje
          [c] wymaga zrozumienia istniejącego kodu głębiej niż manifest → czyta pliki
W4.3  [LLM]            Wygeneruj plan rewizji
W4.4  [loop]           Dla każdej rewizji → wywołaj W2
W4.5  [deterministic]  Oznacz Instruction jako completed
W4.6  [deterministic]  Triggeruj W3 (restart preview)
```

### W5: Undo

Triggerowany przez: tool call `UndoLastChange`.

```
W5.1  [deterministic]  Znajdź ostatnią completed rewizję
W5.2  [deterministic]  Git revert (nowy commit, nie reset)
W5.3  [deterministic]  Utwórz nową Revision z git_sha revertu
W5.4  [LLM]            Zaktualizuj app manifest (docs/)
W5.5  [deterministic]  Triggeruj W3 (restart preview)
```

### W6: Cancel

Triggerowany przez: tool call `CancelInstruction` lub UI button.

```
W6.1  [deterministic]  Przerwij bieżący job (jeśli running)
W6.2  [deterministic]  Oznacz Instruction jako cancelled
W6.3  [deterministic]  Git reset --hard do ostatniej completed rewizji
W6.4  [deterministic]  Oznacz pending rewizje jako cancelled
W6.5  [deterministic]  Raportuj do warstwy konwersacji
```

W6 jest **w pełni deterministyczny**.

---

## Katalog decyzji (non-deterministyczne kroki)

Każde miejsce gdzie LLM podejmuje decyzję, jawnie opisane.

| ID | Workflow | Krok | Decyzja | Opcje |
|----|----------|------|---------|-------|
| D1 | W1 | W1.2 | Czy archetype pokrywa wymagania? | [a] tak → skip research [b] nie → dodatkowy research |
| D2 | W2 | W2.6 | Co zmieniło się w dokumentacji? | LLM generuje diff do app manifest + revision notes |
| D3 | W4 | W4.2 | Ile researchu potrzeba? | [a] manifest wystarczy [b] szukaj nowych rozwiązań [c] czytaj kod |
| D4 | Chat | — | Kiedy triggerować workflow? | Agent interpretuje intent usera → tool call |
| D5 | Chat | — | Co zasugerować userowi? | Agent generuje suggested prompts |
| D6 | Chat | — | Jak zareagować na failure? | Agent decyduje: zmiana podejścia / pytanie do usera (ma błędy weryfikacji w kontekście) |

---

## Agent — jedyny niestrukturyzowany element

Agent konwersacyjny (RubyLLM + tools) jest jedynym miejscem z prawdziwie autonomicznymi decyzjami:
- Interpretuje co user ma na myśli
- Decyduje kiedy pytać, kiedy generować, kiedy sugerować
- Reaguje na eventy (failure, completion) z workflow'ów

Ale nawet agent jest ograniczony:
- Ma zdefiniowany zestaw narzędzi (tools) — nie może zrobić czegoś czego nie przewidzieliśmy
- System prompt definiuje jego zachowanie i granice
- Nie wykonuje kodu — triggeruje workflow'y

---

## Roast — engine workflow'ów

Roast (Shopify) — Ruby DSL do orkiestracji workflow'ów z mieszanymi krokami (deterministyczne + LLM). Session replay, Claude Code integration, production-tested w Shopify.

Przykład W2 w Roast (zwalidowany w spike — `roast-spike/test_agent.rb`):

```ruby
# workflows/revision_workflow.rb
# Uruchomienie: roast revision_workflow.rb -- revision_id=123 workspace=/path/to/project

config do
  agent do
    provider :claude
    model "sonnet"
    working_directory WORKSPACE   # Claude CLI pisze do workspace'u projektu
    skip_permissions!             # batch mode, nie pytamy o pozwolenie
  end
  cmd { display! }
end

# Remediation scope — naprawia błędy weryfikacji
execute(:fix_and_verify) do
  agent(:fix) do |_, errors|
    "Weryfikacja nie przeszła. Napraw błędy:\n\n#{errors}"
  end
  ruby(:verify) do
    errors = run_checks(kwarg(:workspace))
    fail!(errors) if errors.present?
    "all checks passed"
  end
  ruby { |_, _, idx| break! if ruby?(:verify) || idx >= 2 }
  outputs { ruby?(:verify) ? "ok" : ruby(:verify).error }
end

# Main workflow
execute do
  ruby(:mark_generating) { ... }  # update DB

  agent(:generate_code) do
    prompt = build_revision_prompt(kwarg(:revision_id))
    prompt  # string zwrócony z bloku = prompt dla Claude CLI
  end

  ruby(:verify) do
    errors = run_checks(kwarg(:workspace))  # bundle check, db:prepare, herb, boot, tests
    fail!(errors) if errors.present?
    "all checks passed"
  end

  # Remediation loop — skip jeśli verify przeszedł
  repeat(:remediate, run: :fix_and_verify) do
    skip! if ruby?(:verify)
    ruby(:verify).error  # przekaż błędy jako input
  end

  cmd(:git_commit) do |my|
    my.command = "sh"
    my.args = ["-c", "cd #{kwarg(:workspace)} && git add -A && git commit -m '#{kwarg(:summary)}'"]
  end

  agent(:update_docs) { "Update app manifest and write revision notes..." }

  ruby(:mark_completed) { ... }  # update DB, git sha
end
```

## Podział technologii

Trzy warstwy, jasne granice:

```
┌─────────────────────────────────────────┐
│  RubyLLM                                │
│  Komunikacja z userem i LLM-em          │
│  Chat, tools, suggested prompts         │
│  → tool call triggeruje Solid Queue job  │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Solid Queue                            │
│  Punkt połączenia warstw                │
│  Job odpala workflow, broadcastuje      │
│  Turbo Stream po zakończeniu            │
└────────────────┬────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────┐
│  Roast                                  │
│  Orkiestracja po stronie serwera        │
│  Budowa aplikacji klienta (W1-W6)       │
│  Claude CLI, git, pliki, docs           │
└─────────────────────────────────────────┘
```

**RubyLLM** nie wie jak budować aplikacje. Wie jak rozmawiać z userem i kiedy triggerować workflow'y.

**Roast** nie wie co user powiedział. Dostaje Instruction z bazy i wykonuje zdefiniowane kroki.

**Solid Queue** łączy obie warstwy asynchronicznie.

---

## Podsumowanie

| Warstwa | Typ | Narzędzie | Decyzje |
|---------|-----|-----------|---------|
| Konwersacja | Agent | RubyLLM + tools | D4, D5, D6 — interpretacja usera, sugestie, reakcje |
| Generowanie nowej apki | Workflow W1 | Roast | D1 — czy potrzeba dodatkowy research |
| Wykonanie rewizji | Workflow W2 | Roast | D2 — update docs + revision notes. Verify + remediation loop (max 2 próby) |
| Preview | Workflow W3 | Roast | brak — pełny determinizm |
| Iteracja | Workflow W4 | Roast | D3 — ile researchu |
| Undo | Workflow W5 | Roast | brak poza update docs |
| Cancel | Workflow W6 | Roast | brak — pełny determinizm |
