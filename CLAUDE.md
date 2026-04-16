# Rails App Generator

Generator aplikacji Ruby on Rails — odpowiednik Lovable/bolt.new dla ekosystemu Rails. Wynik: czyste repo Rails, zero vendor lock-in.

## Status (2026-04-16)

- **Faza 1** (spike Roast 1.1 + Claude CLI): **domknięty**. Pipeline driver → Roast → Claude CLI → verify → remediation zwalidowany end-to-end. Kod w `roast-spike/`, wyniki w `roast-spike/findings.md`.
- **Faza 2** (PoC głównej apki generatora: RubyLLM + Solid Queue + Roast per Instruction): **rozpisany** w `10-phase-2-poc-generator-app.md`, **alternatywy A1-A7 rozstrzygnięte 2026-04-16** (dwie zmiany architektoniczne: `CreatePlan` service + lightweight `StartGeneration` tool). Ready do Kroku 1.
- **Faza 3** (preview isolation przez Kamal + Docker): **analiza gotowa** w `20-phase-3-preview-isolation.md`. Poza zakresem Fazy 2.

## Struktura dokumentacji

Pliki w głównym katalogu pogrupowane numerycznie:

- **`0X-*`** — kanon (wizja, user journey, architektura, stack). Czyta się raz, odwołuje wielokrotnie.
- **`1X-*`** — aktywny plan implementacji (obecnie Faza 2).
- **`2X-*`** — plany przyszłych faz (obecnie Faza 3 preview isolation — analiza, jeszcze nieaktywna).
- **`9X-*`** — brainstorm / idea dump (jawnie oznaczone jako nie-kanon).
- **`roast-spike/`** — referencyjna implementacja Fazy 1 (proven, nie ruszać bez powodu).

## Kolejność czytania przy wznawianiu

1. `10-phase-2-poc-generator-app.md` — plan Fazy 2: decyzje architektoniczne, DoD, kroki 1-7, tabela alternatyw, otwarte pytania
2. `roast-spike/findings.md` — co zwalidowane w Fazie 1, jakie gotchas ujawnione
3. `02-user-journey.md` — user story, model danych, architektura (kanon)
4. `03-workflows-and-decisions.md` — W1-W6 workflow definitions + decyzje D1-D6 + Roast example
5. `04-layer-integration.md` — RubyLLM ↔ Roast ↔ Solid Queue przez event bus
6. `05-tech-stack.md` — gemy (stack generatora vs. stack generowanych apek)
7. `01-vision-and-principles.md` — wizja, stałe założenia, ścieżki A/B Quick/Guided, odłożone

Przy aktywacji Fazy 3: dopisać `20-phase-3-preview-isolation.md` do kolejności powyżej, przed kanonem.

Dodatkowe źródła po spike'u:
- `roast-spike/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `roast-spike/verify_revision.rb` — verify helper
- `roast-spike/new_app_driver.rb` — logika przenoszona do `ExecuteInstructionJob` w Fazie 2
- `roast-spike/bin/roast` — wrapper rozwiązujący 3 ENV gotchas

## Konwencje

- Narracja: **polski**. Kod i nazwy techniczne: **angielski**.
- **Rails framing: "Rails Way first"**. Nie pozycjonuj rozwiązań jako "event-driven architecture" ani "Rails na eventach" — community ceni prostotę i convention over configuration, architektoniczne buzzwordy odstraszają. Pokazuj że narzędzia Rails już to mają, wystarczy ich użyć.
- **`.ruby-version` pinuj przez zapisanie pliku** (Write tool), nie przez CLI version managera (`frum local`, `rbenv local`, itp.). User chce sam zweryfikować stan plikiem.
- **Roast runner**: `bin/roast` default (subskrypcja Claude Code — wrapper unsetuje `ANTHROPIC_*` ENV + pinuje PATH na `.ruby-version`). `bin/roast-openrouter` to fallback płatny per-token gdy subskrypcja niewystarczająca. Nie wołaj `bundle exec roast` bezpośrednio — pomija wrapper i rozbija pipeline (3 ENV leaks, szczegóły w `roast-spike/findings.md`).
- Repo wyekstrahowane z hub'a `~/projects/pawel-claude/` (2026-04-16) przez `git subtree split` — historia folderu zachowana. W pawel-claude pozostaje backup aż do potwierdzenia że nowe repo jest OK.
- Nie startować Kroku 1 bez potwierdzenia z userem że plan jest nadal aktualny. Alternatywy A1-A7 rozstrzygnięte 2026-04-16 — kolejna rekonsyderacja możliwa, ale musi być świadomą decyzją.
