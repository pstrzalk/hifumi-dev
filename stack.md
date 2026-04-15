# Stack generowanych aplikacji

Lista narzędzi i gemów używanych w generowanych aplikacjach.
Zasada: Rails Way first. Gem tylko gdy Rails nie ma wbudowanego rozwiązania.

---

## Wbudowane w Rails (zero dodatkowych gemów)

To co Rails 8 daje out of the box. Używamy zawsze gdy pasuje.

| Obszar | Rozwiązanie | Uwagi |
|--------|-------------|-------|
| Background jobs | **Solid Queue** | Default w Rails 8. Nie Redis. |
| WebSockets | **Solid Cable** | Action Cable backend. Nie Redis. |
| Cache | **Solid Cache** | DB-backed cache. Nie Redis. |
| Pliki/uploady | **Active Storage** | Lokalne lub S3. |
| Rich text | **Action Text** | WYSIWYG z Trix. |
| Maile | **Action Mailer** | Z preview w dev. |
| Frontend | **Turbo + Stimulus** | Hotwire. Zero React/Vue. |
| CSS | **Tailwind CSS** | `rails new --css tailwind`. |
| Baza danych | **SQLite** | Default. Wystarczy na start i dalej. |
| Asset pipeline | **Propshaft** | Default w Rails 8. |
| JS bundling | **importmap-rails** | Default. Bez node_modules. |
| Testy | **Minitest** | Rails default. Fixtures, nie factory bot. |
| Recurring jobs | **Solid Queue recurring** | Wbudowane. Bez dodatkowego gema. |

---

## Pewniaki (zawsze dodajemy)

Gemy które rozwiązują realne problemy lepiej niż ręczne implementacje.

### Autentykacja — Devise

```ruby
gem "devise"
```
- Logowanie, rejestracja, reset hasła, potwierdzenie email, blokowanie konta
- Ekosystem pochodnych: `devise_invitable`, `devise-jwt` itp.
- Dlaczego nie Rails 8 `generate authentication`: Devise daje pełny cykl życia konta (maile, zmiana hasła, zaproszenia). Rails generator daje tylko basic login.

### Paginacja — Pagy

```ruby
gem "pagy"
```
- Najszybszy, najlżejszy paginator
- Rails Way: helper + partial, zero magic
- Dlaczego nie Kaminari: Pagy jest szybszy, prostszy, mniej monkey-patchingu

### ERB toolchain — Herb + ReActionView

```ruby
gem "herb"
gem "reactionview"
```
- **Herb** — HTML-aware parser ERB napisany w C. Linter, formatter, LSP, dev tools. Zastępuje `erb_lint` z dużo lepszym parserem (rozumie kontekst HTML, nie tylko tagi ERB).
- **ReActionView** — integracja Herb::Engine z Rails ActionView. Drop-in replacement. Walidacja HTML podczas renderowania, lepsze błędy.
- Herb uruchamiany po każdej rewizji i w git hooks
- Templateki mogą być `.html.erb` (z interception) lub `.html.herb` (natywne)

### Autoryzacja — Pundit

```ruby
gem "pundit"
```
- Policy objects — prosty, przewidywalny pattern
- Rails Way: plain Ruby objects, convention over configuration (app/policies/)
- Dlaczego nie CanCanCan: Pundit jest prostszy, explicit, łatwiejszy do zrozumienia dla nowych developerów

### Admin panel — Avo (Community Edition)

```ruby
gem "avo"
```
- Nowoczesny admin panel, aktywnie rozwijany, dobra integracja z Rails
- Darmowa wersja (Community Edition) na start
- Potencjalna współpraca z twórcami Avo w przyszłości
- Kiedy: apka ma panel admina (większość apek)

---

## Warunkowe (dodajemy gdy potrzebne)

Gemy dodawane w zależności od wymagań projektu. Agent decyduje na podstawie opisu aplikacji.

### Płatności — Pay

```ruby
gem "pay"
```
- Wrapper na Stripe (i Paddle, Braintree)
- Integracja z Rails: modele, hooki, webhooks
- Kiedy: apka ma płatności online
- Alternatywa: bezpośrednio `stripe` gem jeśli potrzeby są bardzo custom

### Wyszukiwanie/filtrowanie — Ransack

```ruby
gem "ransack"
```
- Search forms, sortowanie, filtrowanie
- Kiedy: apka ma listy z wyszukiwarką/filtrami (produkty, zamówienia, etc.)
- Alternatywa: proste scopes jeśli potrzeby minimalne

### Slug-i w URL — FriendlyId

```ruby
gem "friendly_id"
```
- `/products/czerwone-roze` zamiast `/products/42`
- Kiedy: apka ma publiczne URL-e (sklep, blog, portfolio)

### Audyt zmian — PaperTrail

```ruby
gem "paper_trail"
```
- Historia zmian na modelach
- Kiedy: apka wymaga audytu (finanse, medycyna, prawo)

### Eksport danych — Caxlsx

```ruby
gem "caxlsx"
gem "caxlsx_rails"
```
- Generowanie plików Excel
- Kiedy: apka ma raporty/eksporty

### Obrazki — image_processing

```ruby
gem "image_processing", "~> 1.2"
```
- Active Storage variants (resize, crop)
- Wymaga libvips
- Kiedy: apka ma uploady obrazków

### Archiwizacja rekordów

- Brak dedykowanego gema. Prosta implementacja: `archived_at` timestamp + scope.
- Nie używamy soft-delete (Discard, Paranoia) — koncept prowadzi do problemów.
- Kiedy: dane nie powinny być kasowane (zamówienia, konta)

### Dekoratory — brak

- Nie używamy draper / view_component na start
- Rails helpers + partials wystarczą
- View Components rozważymy gdy UI się skomplikuje

---

## Czego NIE używamy

| Nie | Dlaczego |
|-----|----------|
| Redis | Solid Queue/Cable/Cache zastępują |
| React / Vue / Angular | Hotwire only |
| Sidekiq | Solid Queue |
| Webpacker / jsbundling | Importmap |
| Devise alternatives (Sorcery, Clearance) | Devise ma najlepszy ekosystem |
| Bootstrap | Tailwind |
| Haml / Slim | ERB + Herb |
| erb_lint | Herb zastępuje z lepszym parserem |
| GraphQL | REST + Turbo. GraphQL to overengineering dla 99% apek |
| Docker w developmencie | `rails server`. Prostota. |
| Soft-delete (Discard, Paranoia) | Prowadzi do problemów. Archiwizacja przez `archived_at`. |
| Multi-tenancy (ActsAsTenant) | Poza zasięgiem na ten moment |
| RSpec | Minitest jest Rails Way |

---

## Stack naszej aplikacji (generator)

Osobna lista — gemy używane w samym generatorze, nie w generowanych apkach.

| Gem | Po co |
|-----|-------|
| `ruby_llm` | Warstwa konwersacji, chat, tools |
| `roast-ai` (~> 1.1) | Orkiestracja workflow'ów generowania. **Wymaga Ruby >= 3.3.** |
| `devise` | Auth użytkowników generatora |
| `solid_queue` | Background jobs (generowanie, preview) |
| `solid_cable` | Turbo Streams (live progress) |
| `tailwindcss-rails` | UI generatora |
| `turbo-rails` + `stimulus-rails` | Hotwire |

---

## Odłożone decyzje

- **Mailer styling** — Tailwind for email? Premailer? Do rozwiązania gdy zajmiemy się mailami.
