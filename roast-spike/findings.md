# Roast Spike — Findings

Walidacja Roast 1.1.0 (Shopify) pod architekturę z `agents-vs-workflows.md`.

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
- `test_agent.rb` — pełny agent → verify → commit pipeline
- `revision_workflow.rb` — W2 draft (nie testowany, do przepisania po lekcjach ze spike'a)
- `new_app_workflow.rb` — W1 draft (nie testowany, do przepisania)

---

## Lekcje dla docs

1. **Aktualizacja `agents-vs-workflows.md`:** Poprawić Roast example — pliki zamiast klas, `fail!`/`break!` zamiast `rescue_from`
2. **`skip_permissions!` jako requirement:** Dodać do opisu agent config
3. **Ruby 3.3+ requirement:** Roast 1.x wymaga Ruby >= 3.3. Dodać do stack.md.
4. **Session replay:** Darmowe z Roast. Można wznowić workflow od dowolnego kroku — idealne do debugowania i do `--replay` po rate limit.

## Next steps

1. Przepisać `revision_workflow.rb` na wzór `test_agent.rb` (proven pattern)
2. Przetestować na prawdziwej Rails app (nie Calculator)
3. Zmierzyć koszt pełnej generacji z Sonnet
4. Zaktualizować `agents-vs-workflows.md` z poprawnymi przykładami Roast API
