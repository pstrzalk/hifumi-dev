# Rails App Generator

Generator aplikacji Ruby on Rails — odpowiednik Lovable/bolt.new dla ekosystemu Rails. Wynik: czyste repo Rails, zero vendor lock-in.

## Status (2026-04-16)

- **Faza 1** (spike Roast 1.1 + Claude CLI): **domknięta**. Pipeline driver → Roast → Claude CLI → verify → remediation zwalidowany end-to-end. Kod w `spikes/roast/`, wyniki w `spikes/roast/findings.md`.
- **Faza 2** (PoC głównej apki generatora: RubyLLM + Solid Queue + Roast per Instruction): **rozpisana** w `docs/03-plans/01-phase-2-poc-generator-app.md`, **alternatywy A1-A7 rozstrzygnięte 2026-04-16** (dwie zmiany architektoniczne: `CreatePlan` service + lightweight `StartGeneration` tool). Ready do Kroku 1.
- **Faza 3** (preview isolation przez Kamal + Docker): **analiza gotowa** w `docs/03-plans/02-phase-3-preview-isolation.md`. Poza zakresem Fazy 2.

## Struktura dokumentacji

Cała dokumentacja projektu żyje w `docs/`, pogrupowana tematycznie. Numeracja folderów i plików wskazuje kolejność czytania w ramach kategorii. Kod spike'ów osobno.

- **`docs/01-vision/`** — kanon o produkcie: wizja, zasady, user journey. Czyta się raz, odwołuje wielokrotnie.
- **`docs/02-architecture/`** — kanon techniczny: workflow'y i decyzje, integracja warstw, tech stack.
- **`docs/03-plans/`** — aktywne plany implementacji per faza (obecnie Faza 2 + analiza Fazy 3).
- **`docs/09-ideas/`** — brainstorm / idea dump (jawnie oznaczone jako nie-kanon).
- **`spikes/roast/`** — referencyjna implementacja Fazy 1 (proven, nie ruszać bez powodu). Kolejne spike'y: `spikes/<nazwa>/`.

## Kolejność czytania przy wznawianiu

1. `docs/03-plans/01-phase-2-poc-generator-app.md` — plan Fazy 2: decyzje architektoniczne, DoD, kroki 1-7, tabela alternatyw, otwarte pytania
2. `spikes/roast/findings.md` — co zwalidowane w Fazie 1, jakie gotchas ujawnione
3. `docs/01-vision/02-user-journey.md` — user story, model danych, architektura (kanon)
4. `docs/02-architecture/01-workflows-and-decisions.md` — W1-W6 workflow definitions + decyzje D1-D6 + Roast example
5. `docs/02-architecture/02-layer-integration.md` — RubyLLM ↔ Roast ↔ Solid Queue przez event bus
6. `docs/02-architecture/03-tech-stack.md` — gemy (stack generatora vs. stack generowanych apek)
7. `docs/01-vision/01-vision-and-principles.md` — wizja, stałe założenia, ścieżki A/B Quick/Guided, odłożone

Przy aktywacji Fazy 3: dopisać `docs/03-plans/02-phase-3-preview-isolation.md` do kolejności powyżej, przed kanonem.

Dodatkowe źródła po spike'u Fazy 1:
- `spikes/roast/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `spikes/roast/verify_revision.rb` — verify helper
- `spikes/roast/new_app_driver.rb` — logika przenoszona do `ExecuteInstructionJob` w Fazie 2
- `spikes/roast/bin/roast` — wrapper rozwiązujący 3 ENV gotchas

## Konwencje

- Narracja: **polski**. Kod i nazwy techniczne: **angielski**.
- **Rails framing: "Rails Way first"**. Nie pozycjonuj rozwiązań jako "event-driven architecture" ani "Rails na eventach" — community ceni prostotę i convention over configuration, architektoniczne buzzwordy odstraszają. Pokazuj że narzędzia Rails już to mają, wystarczy ich użyć.
- **`.ruby-version` pinuj przez zapisanie pliku** (Write tool), nie przez CLI version managera (`frum local`, `rbenv local`, itp.). User chce sam zweryfikować stan plikiem.
- **Roast runner**: `bin/roast` default (subskrypcja Claude Code — wrapper unsetuje `ANTHROPIC_*` ENV + pinuje PATH na `.ruby-version`). `bin/roast-openrouter` to fallback płatny per-token gdy subskrypcja niewystarczająca. Nie wołaj `bundle exec roast` bezpośrednio — pomija wrapper i rozbija pipeline (3 ENV leaks, szczegóły w `spikes/roast/findings.md`).
- Repo wyekstrahowane z hub'a `~/projects/pawel-claude/` (2026-04-16) przez `git subtree split` — historia folderu zachowana. W pawel-claude pozostaje backup aż do potwierdzenia że nowe repo jest OK.
- Nie startować Kroku 1 bez potwierdzenia z userem że plan jest nadal aktualny. Alternatywy A1-A7 rozstrzygnięte 2026-04-16 — kolejna rekonsyderacja możliwa, ale musi być świadomą decyzją.
