# Roast Spike — Findings

Walidacja Roast 1.1.0 (Shopify) pod architekturę z `03-workflows-and-decisions.md`.

## Verdict: działa. Architektura trafiona, API surface wymaga korekt.

Wszystkie kluczowe elementy przetestowane i działają:
- `cmd()`, `ruby()`, `agent()` — generate → verify → commit pipeline
- `repeat()` + `fail!` + `break!` — remediation loop
- `working_directory` + `skip_permissions!` — Claude CLI pisze do wskazanego katalogu
- `kwarg()` — parametry z CLI
- Data passing przez bang suffix (`cmd!(:name)`, `ruby!(:name).value`)

---

## Przetestowane (z wynikami)

### test_basic.rb — cmd + ruby + data passing
```
cmd(:hello) → ruby(:process) → cmd(:result)
Result: "Processed: HELLO FROM ROAST (16 chars)"
```

### test_remediation.rb — remediation loop pattern
```
generate → initial_verify(FAIL) → repeat(:remediate):
  iteration 0: fix → verify(FAIL) → continue
  iteration 1: fix → verify(FAIL) → continue
  iteration 2: fix → verify(PASS) → break!
Result: "remediation succeeded"
```

### test_agent.rb — pełny pipeline z Claude CLI
```
cmd(:setup) git init → agent(:generate) Claude CLI → cmd(:verify) minitest → cmd(:commit) git
Agent stats: 3 turns, 7 seconds, $0.015 (Haiku)
Verify: 3 runs, 9 assertions, 0 failures, 0 errors
Commit: c63ae93 — 2 files
```

---

## Co trzeba poprawić w naszych docs

### 1. Workflow = plik .rb, nie klasa Ruby

**Docs mówią:**
```ruby
class RevisionWorkflow < Roast::Workflow
  execute do ...
```

**Roast naprawdę:**
```ruby
# revision_workflow.rb (plain file)
config do ...
execute do ...
```

**Wpływ na architekturę:** Integracja z naszą apką Rails przez `system("roast", "execute", "workflow.rb", ...)` z Solid Queue joba. Nie `RevisionWorkflow.new.call`. Mniej Ruby-native, ale session replay i tracing dostajemy za darmo.

### 2. Error handling: `fail!` + `repeat()`, nie `rescue_from`

**Docs mówią:**
```ruby
rescue_from VerificationFailed do |errors|
  retry_count = 0
  loop do ...
```

**Roast naprawdę:** `rescue_from` nie istnieje. `fail!` oznacza cog jako failed ale workflow kontynuuje. Remediation loop przez:
- `ruby(:verify)` z `fail!` gdy check nie przechodzi
- `ruby?(:verify)` zwraca false dla failed coga
- `repeat(run: :fix_scope)` z `break!` w środku

Przetestowane — działa dobrze. Pattern jest nawet czytelniejszy niż rescue.

### 3. Parametry: `kwarg(:key)`, nie constructor args

CLI: `roast workflow.rb -- revision_id=123 workspace=/tmp/app`
Workflow: `kwarg(:revision_id)`, `kwarg(:workspace)`

Format: `key=value`, nie `--key value`.

### 4. `repeat` nie ma `max_iterations` — sterowanie przez `break!`

```ruby
execute(:fix_scope) do
  agent(:fix) { |_, errors| "Napraw: #{errors}" }
  ruby(:verify) { fail! if checks_fail }
  ruby { |_, _, idx| break! if ruby?(:verify) || idx >= 2 }
  outputs { ruby?(:verify) ? "ok" : "errors: ..." }
end
```

### 5. Agent wymaga `skip_permissions!` i `working_directory`

Bez `skip_permissions!` Claude CLI pyta o pozwolenie na zapis (i nie dostaje odpowiedzi w batch mode → timeout/fail).

```ruby
config do
  agent do
    provider :claude
    model "sonnet"
    working_directory "/path/to/workspace"
    skip_permissions!
  end
end
```

**Uwaga bezpieczeństwa:** `skip_permissions!` = `--dangerously-skip-permissions` w Claude CLI. Akceptowalne bo workspace jest izolowany per projekt. Ale potwierdza, że preview isolation (kontenery) jest konieczna w produkcji.

---

## Koszty (zmierzone)

| Operacja | Model | Czas | Koszt |
|---|---|---|---|
| agent(:generate) — 2 pliki Ruby | Haiku | 7s | $0.015 |

Dla pełnej generacji Rails app (6 rewizji × Sonnet) szacunek: 6 × ~$0.10-0.30 = **$0.60-1.80 per instruction**. Plus planning, research, doc updates. Realnie **$1-3 per generacja** z Sonnet. Z remediation loop: do $5.

---

## Pliki spike'a

- `test_basic.rb` — cmd + ruby + data passing (10s test)
- `test_remediation.rb` — repeat + fail! + break! pattern
- `test_agent.rb` — pełny agent → verify → commit pipeline (proven pattern)
- `revision_workflow.rb` — W2 (proven, odpalone na planie todo-list)
- `new_app_driver.rb` — Ruby wrapper odpowiadający przyszłemu Solid Queue job'owi: rails new + pętla shellująca `bin/roast revision_workflow.rb`
- `new_app_workflow.rb` — W1 draft (nieużywany — driver go zastąpił)
- `verify_revision.rb` + `bin/verify` — deterministyczny verify helper
- `plans.rb` — `todo-list` (3 rewizje happy path) i `force-remediation` (1 rewizja z wymuszonym failem)
- `bin/roast` — wrapper na subskrypcję Claude Code (unset API env + pin Ruby z .ruby-version)
- `bin/roast-openrouter` — fallback płatny przez OpenRouter

---

## Pełny pipeline przetestowany end-to-end (2026-04-15)

Plan `todo-list` (3 rewizje × Sonnet) uruchomiony przez `new_app_driver.rb` pod subskrypcją Claude Code. Wynik: **3/3 completed, 496s wall, zero remediation**. Dowód: `tmp/metrics_todo-list_1776288069.json`, git log w `tmp/todo-spike/`.

| Rewizja | Wall | SHA |
|---|---|---|
| Todo model + walidacje + testy | 128s | 404e402 |
| TodosController (REST) + testy | 142s | ef00bc3 |
| Widoki Tailwind + Hotwire Turbo | 226s | dc141e3 |

Każda rewizja verify'owana przez sekwencję: `bundle check` → `db:prepare` → `herb lint` (skipped bo gem nie zainstalowany) → `boot check` → `rails test`. Wszystkie PASS.

### Trzy ENV gotchas które trzeba było naprawić żeby pipeline przeszedł

Wszystkie silent killers, każdy blokował cały run. Fixy w commit b94e9a7. Szczegóły w memory `feedback_roast_rails_env_gotchas.md`:

1. **`ANTHROPIC_API_KEY` wycieka do Claude CLI** (driver przez `bundle exec roast` zamiast `bin/roast`) → Claude idzie na API, dostaje 429. Fix: driver MUSI wołać `bin/roast`.
2. **frum shim rozwiązuje złą wersję Ruby** gdy `bundle` jest spawnowany jako subprocess pod innym Ruby niż `.ruby-version`. `GemNotFound` dla gemów Roasta. Fix: `bin/roast` pinuje PATH na `$HOME/.frum/versions/$(cat .ruby-version)/bin`.
3. **`BUNDLE_GEMFILE` wycieka z `bundle exec roast` do `bin/rails` w workspace** — workspace ładuje gemy spike'a, `bootsnap/setup` LoadError. Fix: `VerifyRevision.with_clean_bundler_env` unsetuje `BUNDLE*`/`BUNDLER*`/`RUBYOPT` przed shellem do workspace.

---

## Koszty (zmierzone)

| Operacja | Model | Czas | Koszt |
|---|---|---|---|
| agent(:generate) — 2 pliki Ruby | Haiku | 7s | $0.015 |
| Pełny W1 todo-list (3 rewizje) | Sonnet przez subskrypcję | 496s wall | $0 realnie (pokryte subskrypcją) |

**Uwaga:** Claude CLI w logu Roasta raportuje "informacyjną" wycenę (np. $0.13 za rewizję 1, ~$1.5 sumarycznie dla todo-list) — to wycena API, nie realne obciążenie subskrypcji. Jeśli potrzebna twarda liczba do DoD, trzeba uruchomić ten sam pipeline przez `bin/roast-openrouter` jednorazowo (plan Kroku 5 w tor-1-plan.md — opcjonalny).

---

## Lekcje dla docs

1. **`03-workflows-and-decisions.md`:** Poprawić Roast example — pliki zamiast klas, `fail!`/`break!` zamiast `rescue_from`
2. **`skip_permissions!` jako requirement** dla agent config
3. **Ruby 3.3+ requirement** (Roast 1.x). Dodać do `05-tech-stack.md`.
4. **Session replay:** darmowe z Roast, można wznowić workflow od kroku — dobre do debugowania i `--replay` po rate limit.
5. **ENV hygiene w driverze/wrapperze:** trzy leaks (punkt wyżej) są na tyle systemowe, że warto je opisać w architekturze jako requirement, nie tylko workaround.

## Krok 4 domknięty — remediation loop zweryfikowany (2026-04-16)

Plan `force-remediation` (1 rewizja × Sonnet) — prompt z jawną sprzecznością: walidacja `price_cents >= 100` + test oczekujący valid dla `price_cents: 50`. Wynik: **all_succeeded, 131s wall, 1 iteracja remediation**. Dowód: `tmp/metrics_force-remediation_1776291035.json`, `tmp/remediation-spike/`.

Pełna ścieżka workflow:
1. `generate_code` → Claude napisał literalnie jak kazaliśmy (walidacja + test ze sprzecznością)
2. `verify` (W2.4) → `bundle` / `db:prepare` / `boot` PASS, `rails test` **FAIL** z assercji "Price cents must be greater than or equal to 100"
3. `repeat(:remediate)` → `fix_and_reverify[0]` → `agent(:fix)` zdiagnozował i wybrał: usunąć `greater_than_or_equal_to: 100`, zachować test
4. `reverify` → PASS → `break!` po pierwszej próbie
5. W2.5 commit kod → W2.6 update docs → W2.7 commit docs → W2.8 report

### Bug wyłapany: `metadata` nie istnieje w Roast DSL blocks

Pierwsza próba wysypała się z `NameError: undefined local variable or method 'metadata' for Roast::CogInputContext`. W `test_agent.rb` i happy path todo-list bug nie wystrzelił, bo `verify` zawsze przechodził za pierwszym razem i linia z `metadata[:verify_errors] = errors` się nie wykonywała.

**Fix:** moduł-level hash `WORKFLOW_STATE = {}` zdefiniowany na górze pliku `revision_workflow.rb`, używany do przeniesienia errors z `ruby(:verify)` do `repeat(:remediate)` bloku. Commit `fc5f4cd`.

**Implikacja dla docs:** przykład W2 w `03-workflows-and-decisions.md` używał `ruby(:verify).error` — to też nie zadziałało w praktyce (cog po `fail!` nie udostępnia `.error`). Zaktualizowany do `WORKFLOW_STATE` pattern.

---

## Verdict: IDZIEMY do Toru 2 (PoC głównej apki generatora)

Architektura W1 → W2 + remediation zweryfikowana end-to-end na realnej Rails app. Happy path i failure path oba domknięte. Stack Roast 1.1 + Claude Code CLI + Ruby wrapper (odpowiednik Solid Queue joba) działa.

Znane ograniczenia i gotchas udokumentowane:
- `metadata` niedostępne w DSL blocks — workaround: moduł-level hash
- Trzy ENV leaks (`ANTHROPIC_API_KEY` / frum Ruby shim / `BUNDLE_GEMFILE`) — workaround: `bin/roast` wrapper + `VerifyRevision.with_clean_bundler_env`
- `skip_permissions!` wymaga izolowanego workspace (→ Tor X: preview isolation z Kamal+Docker)

## Next steps (co zostało z tor-1-plan.md)

1. ✅ ~~Przepisać revision_workflow.rb na wzór test_agent.rb~~
2. ✅ ~~Przetestować happy path na prawdziwej Rails app (plan todo-list, 3 rewizje)~~
3. ✅ ~~Uruchomić plan `force-remediation` — remediation loop zweryfikowany~~
4. ⬜ (Opcjonalnie, odłożone) realny koszt przez OpenRouter — subskrypcja nie pokazuje tokenów; do zmierzenia gdy DoD Toru 2 tego wymaga
5. ✅ ~~Update dokumentów (`findings.md`, `03-workflows-and-decisions.md` — commit ff73377; `index.md` został później zlikwidowany przy reorganizacji dokumentacji)~~
6. ✅ ~~Cleanup: `tor-1-plan.md` usunięty (commit ff73377), pamięci `project_tor_1_*` nigdy nie istniały na tym hoście~~

**Tor 1 domknięty 2026-04-16. Dalej: Tor 2 — `10-tor-2-poc-generator-app.md` (PoC apki generatora — RubyLLM + Solid Queue + Roast).**
