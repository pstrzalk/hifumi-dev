# Rails App Generator

> **From PROMPT to IPO.**
> Convention over configuration means agents write token-efficient code that's easy to generate and beautiful for humans to review.
> — inspired by rubyonrails.org (2026)

Generator aplikacji Ruby on Rails — odpowiednik Lovable/bolt.new dla ekosystemu Rails.

## Wizja

Rails sam się pozycjonuje jako framework optymalny dla agentów AI — convention over configuration oznacza mniej tokenów, mniej decyzji, lepszy output. My bierzemy to dosłownie: narzędzie, które na podstawie opisu w języku naturalnym generuje kompletną aplikację Rails. Użytkownik mówi np. "Stwórz aplikację do sprzedaży i dostawy kwiatów", a system prowadzi go przez proces tworzenia gotowej aplikacji.

**To jest narzędzie popularyzujące Ruby on Rails.** Wynik to czyste repo Rails — zero vendor lock-in, zero proprietary gemów. `git clone`, `bundle install`, `rails server`. User kontynuuje pracę standardowymi narzędziami: dowolny edytor, dowolne CI, dowolny hosting. Nasz generator to ramp-up, nie klatka.

## Stałe założenia (non-negotiable)

- **Główna aplikacja** (sam generator) — Ruby on Rails
- **Generowane aplikacje** — Ruby on Rails

## Koncept procesu generowania

Dwie ścieżki do wyboru przez użytkownika:

### Ścieżka A: Quick generate
1. **Input** — użytkownik opisuje aplikację
2. **Generowanie** — system podejmuje decyzje sam, opinionated defaults, szybki wynik
3. **Iteracja** — użytkownik modyfikuje to co dostał

### Ścieżka B: Guided generate
1. **Input** — użytkownik opisuje aplikację
2. **Clarifying questions** — 2-3 pytania doprecyzowujące
3. **Scaffolding** — rails generators, Tailwind, SQLite, standardowe rozwiązania Rails
4. **Domain modeling** — modele, relacje, walidacje
5. **Capabilities** — kolejne fazy dostarczają funkcjonalności
6. **Layout/design** — kolory, fonty, layout (późniejszy krok)

## Decyzje techniczne

### Stack generowanych aplikacji
- Maksymalnie "Rails Way" — konwencje, generatory, wbudowane rozwiązania
- Tailwind CSS
- SQLite (domyślnie)
- Solid Cable/Queue/Cache zamiast Redis tam gdzie to możliwe
- **Devise** do autentykacji — ogarnia maile, zmianę hasła, a pochodne gemy (devise_invitable etc.) dają pełny ekosystem
- **Hotwire only** — Turbo + Stimulus, zero React/Vue
- **HERB + ReActionView** — lintowanie i formatowanie plików ERB
- Standardowe Rails'owe podejście (Action Mailer, Active Storage, etc.)

### Interfejs generatora
- **Od razu web UI** — to jest docelowa forma produktu
- **Skrypty CLI obok** — każdy element procesu generowania powinien być wykonywalny z CLI, żeby można było testować, debugować i powtarzalnie sprawdzać kroki pipeline'u

### Kontekst Rails Way
- Na start: bazowa wiedza LLM-a + baza archetypów aplikacji (nasz core IP)
- App manifest (docs/) w generowanych apkach — samodokumentująca się struktura
- Przyszłość: progressive disclosure — dostarczanie wiedzy na żądanie
- **Ruby on Rails Guides** jako źródło prawdy o konwencjach. Możliwości: Context7 MCP, bezpośrednia integracja z guides, własna baza wiedzy zasilana z guides. Rails Foundation jest dumna z Guides — chcemy je uchonorować, nie obejść.
- Pętla zwrotna: generowane aplikacje → feedback o tym które patterns działają → zasilanie bazy archetypów i wiedzy

### Deployment (przyszłość, nieskonkretyzowane)
- **Kamal** — jeśli klient chce sam deployować (self-hosted)
- **In-house hosting** — jeśli aplikacje trzymane są "u nas" (model SaaS?)
- Deployment jest ważny, ale szczegóły do wypracowania później

## Silnik generowania

Trzy warstwy:
- **RubyLLM** — komunikacja z userem, chat, tools. Triggeruje workflow'y.
- **Roast** (Shopify) — orkiestracja workflow'ów po stronie serwera. Zdefiniowane kroki z LLM w środku.
- **Claude Code CLI** — generowanie kodu wewnątrz workflow'ów Roast.

Solid Queue łączy warstwy asynchronicznie. Szczegóły: `agents-vs-workflows.md`, `happy-path.md`

## Odłożone na później

- **In-house hosting** — model do wypracowania (Kamal dla self-hosted)
- **Mailer styling** — Tailwind for email? Premailer? Do rozwiązania przy mailach.
- **Rails on WebAssembly** — Evil Martians pokazali, że da się odpalić Rails + część gemów w WASM bezpośrednio w przeglądarce. Do sprawdzenia jako ścieżka "try it now" dla wygenerowanych projektów — zero setup, game-changer dla UX generatora. Deployment nie jest pierwszym zmartwieniem, ale gdyby zadziałało, byłoby bardzo mocne. Źródła: [evilmartians.com/chronicles/ruby-on-rails-on-webassembly](https://evilmartians.com/chronicles/ruby-on-rails-on-webassembly-a-guide-to-full-stack-in-browser-action), kontynuacja na [writebook-on-wasm.fly.dev](https://writebook-on-wasm.fly.dev/5/ruby-on-rails-on-webassembly/).
- **Finansowanie tokenów LLM** — trzeba znaleźć sponsora na koszty tokenów. Świadomie nie chcę polegać na Visuality — jeśli projekt wypali, chcę być jedynym właścicielem. Anthropic historycznie dawał darmowe tokeny, ostatnio rzadziej. Do rozważenia: kontakt z local ambasadorami Anthropic, inne programy sponsorskie.

## Dokumenty

- `happy-path.md` — user story, model danych, architektura
- `agents-vs-workflows.md` — katalog workflow'ów i decyzji
- `stack.md` — gemy i narzędzia
- `git-integration-ideas.md` — pomysły na integrację z git
- `preview-isolation.md` — izolacja preview: Kamal + Docker + kamal-proxy
- `roast-spike/` — spike walidujący Roast 1.1.0 (wyniki w `findings.md`)

## Status

Faza: **spike Roast domknięty (2026-04-16), Tor 2 ready to start**.

Zwalidowane end-to-end:
- Architektura W1 → W2 z remediation loop (`roast-spike/`)
- Happy path: plan `todo-list` (3 rewizje × Sonnet, 496s)
- Failure path: plan `force-remediation` (1 rewizja, 1 iteracja remediation, 131s)
- Stack Roast 1.1 + Claude Code CLI + Ruby wrapper (odpowiednik przyszłego Solid Queue joba)

Verdict w `roast-spike/findings.md`. Tor 2: PoC głównej apki generatora (RubyLLM chat + Solid Queue + wywołanie Roast per Instruction).
