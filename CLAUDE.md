# Rails App Generator

Generator aplikacji Ruby on Rails — odpowiednik Lovable/bolt.new dla ekosystemu Rails. Wynik: czyste repo Rails, zero vendor lock-in.

## Status (2026-04-16)

- **Tor 1** (spike Roast 1.1 + Claude CLI): **domknięty**. Pipeline driver → Roast → Claude CLI → verify → remediation zwalidowany end-to-end. Kod w `roast-spike/`, wyniki w `roast-spike/findings.md`.
- **Tor 2** (PoC głównej apki generatora: RubyLLM + Solid Queue + Roast per Instruction): **rozpisany** w `tor-2-plan.md`, ready do Kroku 1.

## Kolejność czytania przy wznawianiu

1. `tor-2-plan.md` — plan Toru 2 + 7 alternatyw (A1-A7) do ewentualnej rekonsyderacji + otwarte pytania
2. `roast-spike/findings.md` — co zwalidowane, jakie gotchas ujawnione
3. `happy-path.md` — user story, model danych, architektura (kanon)
4. `agents-vs-workflows.md` — W1-W6 workflow definitions + Roast example
5. `layer-integration.md` — RubyLLM ↔ Roast ↔ Solid Queue przez event bus
6. `stack.md` — gemy (stack generatora vs. stack generowanych apek)
7. `index.md` — oryginalny wstęp projektu (z hub pawel-claude)

Dodatkowe źródła po spike'u:
- `roast-spike/revision_workflow.rb` — W2 DSL (Implement → Verify → Commit + remediation)
- `roast-spike/verify_revision.rb` — verify helper
- `roast-spike/new_app_driver.rb` — logika przenoszona do `ExecuteInstructionJob` w Torze 2
- `roast-spike/bin/roast` — wrapper rozwiązujący 3 ENV gotchas

## Konwencje

- Narracja: **polski**. Kod i nazwy techniczne: **angielski**.
- Repo wyekstrahowane z hub'a `~/projects/pawel-claude/` (2026-04-16) przez `git subtree split` — historia folderu zachowana. W pawel-claude pozostaje backup aż do potwierdzenia że nowe repo jest OK.
- Nie startować Kroku 1 bez potwierdzenia z userem że plan Toru 2 jest nadal aktualny — możliwa rekonsyderacja którejś z alternatyw A1-A7.
