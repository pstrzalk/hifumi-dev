# Tor 1 — Domknięcie spike'a Roast

> **Uwaga:** Ten dokument jest tymczasowy. Po zamknięciu Toru 1 (wszystkie kroki ✅) — usunąć plik i zaktualizować `index.md` (status przejdzie z "koncepcja zamknięta" na "spike domknięty, PoC w trakcie/start").

## Cel

Zwalidować end-to-end, że architektura opisana w `agents-vs-workflows.md` (W1 → W2 z remediation) działa na prawdziwej Rails app z Sonnetem. Domykamy tor zanim zaczniemy budować główną apkę generatora (Tor 2).

## Definition of Done

- `revision_workflow.rb` i `new_app_workflow.rb` przepisane na proven pattern z `test_agent.rb`, oba uruchomione na prawdziwej apce, oba zielone
- Zmierzony realny koszt pełnej generacji (W1 × N rewizji) z Sonnet — pojedyncza liczba + breakdown per rewizja
- Remediation loop zweryfikowany na prawdziwym błędzie (nie symulowanym) — failure → Claude naprawia → verify przechodzi
- `agents-vs-workflows.md` i `stack.md` zaktualizowane, `findings.md` zamknięte z verdictem "idziemy dalej / nie idziemy"

## Kroki

### 1. Przepisanie workflow'ów na proven pattern

**1a. `revision_workflow.rb` (W2)**
- Bazować na `test_agent.rb` (zwalidowany pipeline: git init → agent → verify → commit)
- Dołożyć: remediation loop (`repeat(:remediate)` + `fail!` + `break!`) wg wzoru z `test_remediation.rb`
- Parametry: `kwarg(:revision_id)`, `kwarg(:workspace)`, `kwarg(:summary)`
- Kroki wg `agents-vs-workflows.md` W2.1–W2.8
- Verify = sekwencja: `bundle check` → `rails db:prepare` → `herb lint` → `rails runner "puts :ok"` → `rails test`
- Verify jako helper Ruby (nie inline w workflow) — łatwiej testować standalone

**1b. `new_app_workflow.rb` (W1)**
- Orkiestracja: archetype → (opcjonalnie research) → plan → N × wywołanie W2
- Wywołanie W2 przez `system("roast", "revision_workflow.rb", ...)` z poziomu W1? Albo jako sub-execute? **Do rozstrzygnięcia w trakcie** — jeśli Roast nie wspiera composition, fallback: W1 generuje plan + rekordy Revision w bazie, orkiestracja rewizji przez Ruby (Solid Queue job) który woła `roast revision_workflow.rb` per rewizja
- Na spike nie potrzebujemy bazy danych — wystarczy JSON z planem + pętla w Ruby która woła W2 per krok

### 2. Wybór testowej apki

Nie Calculator (za prosty). Kryteria:
- Reprezentuje realny archetype (prosty, ale z modelami + relacjami)
- Max 4-6 rewizji, żeby nie przepalać tokenów w spike'u
- Można zweryfikować ręcznie że działa

**Propozycja:** mini-blog. Rewizje:
1. `rails new` + gems (Devise, Tailwind)
2. Model `Post` (title, body, published_at) + migracja
3. CRUD scaffold (kontroler, widoki, routes)
4. Devise dla autorów
5. Listing + single post view z Tailwindem
6. Seed data + minimalne testy

Alternatywa: todo list z kategoriami (prostszy, ale mniej pokazuje).

**Decyzja:** zaczynamy od todo listy (3 rewizje), potem eskalujemy do bloga jeśli todo przechodzi.

### 3. Uruchomienie pełnego pipeline'u

- Workspace: `rails-app-generator/roast-spike/tmp/test-app/`
- Uruchomienie: `roast new_app_workflow.rb -- prompt="todo list z kategoriami"`
- Logging: każdy krok, czas, koszt, status verify
- Oczekiwany wynik: git repo z N commitami, każdy commit = jedna completed rewizja, apka bootuje

### 4. Test remediation loop

Dwa scenariusze:
- **Naturalny failure** — przepuścić przez pipeline jak leci, jeśli w którejś rewizji verify padnie naturalnie → obserwować czy remediation naprawia
- **Wymuszony failure** — jeśli naturalny się nie pojawi, dołożyć na siłę błąd (np. literówkę w migracji przez edit promptu) i zobaczyć czy Claude go naprawi

Mierzymy: ile prób, ile tokenów per remediation, czy po 2 próbach failure path działa (reset do parent).

### 5. Pomiar kosztów

Dla każdego uruchomienia pełnego W1:
- Liczba rewizji
- Suma tokenów (input + output) per rewizja
- Koszt per rewizja (Sonnet)
- Koszt całości
- Czas wall-clock

Cel: zweryfikować szacunek z `findings.md` ($1-3 per generacja, do $5 z remediation). Jeśli realny koszt wyjdzie znacząco wyżej → trzeba zrewidować założenia (mniejszy model, krótsze prompty, cache).

### 6. Update dokumentów

**6a. `findings.md`** — sekcja "Zamknięcie spike'a":
- Realny koszt pełnej generacji (liczby)
- Czy architektura W1/W2 zadziałała bez korekt czy wymagała zmian
- Lista gotchas napotkanych przy pisaniu workflow'ów na prawdziwej apce
- Verdict: idziemy do Toru 2 (PoC głównej apki) / nie idziemy / idziemy z korektami

**6b. `agents-vs-workflows.md`** — review czy przykład W2 (już zaktualizowany po spike'u) zgadza się z finalną wersją `revision_workflow.rb`. Jeśli coś się rozjechało — zsynchronizować.

**6c. `stack.md`** — dodać Ruby 3.3+ jako requirement (z findings.md pkt 3).

**6d. `index.md`** — status na "spike domknięty, Tor 2 (PoC) ready to start".

### 7. Cleanup

- Usunąć ten plik (`tor-1-plan.md`)
- Usunąć memory `project_tor_1_plan` jeśli została utworzona
- Jeśli `roast-spike/tmp/` jest ciężkie → gitignore albo cleanup

## Kolejność wykonania

Sekwencyjnie — każdy krok zależy od poprzedniego.

1 → 2 → 3 → 4 (remediation) → 5 (pomiar — w trakcie 3-4) → 6 (update docs) → 7 (cleanup)

Kroki 3-5 dzieją się częściowo równolegle — uruchamiając pipeline zbieramy dane o koszcie i remediation przy okazji.

## Ryzyka / unknowns

- **Roast composition (W1 woła W2)** — nie wiemy czy Roast to wspiera natywnie. Plan awaryjny: Ruby wrapper + `system("roast", ...)`. Do rozstrzygnięcia w trakcie kroku 1b.
- **Koszt może przebić szacunek** — jeśli realne generowanie z Sonnet kosztuje $10+ per apka, to problem z jakością promptów albo architekturą. Nie jest to blocker Toru 1, ale input do decyzji o Torze 2.
- **Verify na prawdziwej apce jest wolny** — `bundle install` + `db:prepare` per rewizja może trwać minuty. Optymalizacja (shared bundle cache) — na razie nie, mierzymy goły czas.
- **Remediation może nie triggerować się naturalnie** — Claude Sonnet robi na ogół działający kod za pierwszym razem na prostych zadaniach. Przygotować wymuszony failure case.
