# frozen_string_literal: true

# Hardcoded plany dla spike'a. W produkcji plan generuje LLM (W1.3).
# Każdy plan = lista rewizji. Każda rewizja: summary (commit msg) + prompt (dla Claude CLI).

module Plans
  TODO_LIST = [
    {
      summary: "Add Todo model with title, body, done, category",
      prompt: <<~PROMPT
        Utwórz model Todo z polami:
        - title (string, required)
        - body (text, optional)
        - done (boolean, default false)
        - category (string, optional)

        Wymagania:
        - Migration z odpowiednimi typami i indeksami
        - Walidacje w modelu (title required, minimum length 1)
        - Fixtures w test/fixtures/todos.yml (przynajmniej 2 rekordy)
        - Test modelu w test/models/todo_test.rb (test walidacji)
        - Uruchom `bin/rails db:migrate` po utworzeniu migracji

        Nie dodawaj kontrolerów ani widoków — to będzie następny krok.
      PROMPT
    },
    {
      summary: "Add TodosController with index/show/new/create/edit/update/destroy",
      prompt: <<~PROMPT
        Utwórz pełny REST controller TodosController z akcjami: index, show, new, create, edit, update, destroy.

        Wymagania:
        - `resources :todos` w config/routes.rb
        - Strong parameters (title, body, done, category)
        - Flash messages po create/update/destroy
        - Redirects po mutacjach (do index albo do show)
        - Controller test w test/controllers/todos_controller_test.rb pokrywający wszystkie akcje
        - Nie twórz widoków jeszcze — index/show/new/edit mogą zwracać pusty HTML na razie
        - Wszystkie testy kontrolera muszą przechodzić (bin/rails test)

        Root route może zostawać jaki był — nie zmieniaj `root`.
      PROMPT
    },
    {
      summary: "Add Tailwind views for Todo with Hotwire Turbo",
      prompt: <<~PROMPT
        Dodaj widoki Tailwind dla Todo z Hotwire Turbo Frames i Turbo Streams.

        Wymagania:
        - app/views/todos/index.html.erb — lista todos w tabeli albo cards, ze stylem Tailwind
        - app/views/todos/show.html.erb — szczegóły z linkami edit/destroy
        - app/views/todos/new.html.erb + edit.html.erb — formularze (shared _form partial)
        - app/views/todos/_todo.html.erb partial — jeden todo item
        - Turbo Frame `dom_id(@todo)` dla optymistycznych updates
        - Checkbox "done" toggluje przez Turbo Stream (optional — jeśli łatwo)
        - Status badge: zielony "Done" vs szary "Todo"
        - Działający nagłówek nawigacji z linkiem do /todos
        - Root route na TodosController#index (zmień config/routes.rb)
        - Testy kontrolera muszą dalej przechodzić

        Nie instaluj nowych gemów. Używaj tego co jest (Tailwind, Turbo zainstalowane przez `rails new --css tailwind`).
      PROMPT
    }
  ].freeze

  # Mini plan z wymuszonym błędem weryfikacji — do testowania remediation loop.
  # Rewizja 1 celowo instruuje żeby zostawić NIEPRZECHODZĄCY test — verify padnie
  # (rails test fail), Claude dostanie błędy i ma naprawić w remediation.
  FORCE_REMEDIATION = [
    {
      summary: "Add Product model with deliberately failing test",
      prompt: <<~PROMPT
        Utwórz model Product z polami:
        - name (string, required, minimum length 2)
        - price_cents (integer, required, >= 0)

        Wymagania:
        - Migration, walidacje w modelu
        - `bin/rails db:migrate`
        - Test w test/models/product_test.rb — musi zawierać przynajmniej jeden test który przechodzi

        WAŻNE: wywołaj `bin/rails test` na końcu. Jeśli któryś test NIE przechodzi,
        zdiagnozuj i popraw. Nie zostawiaj broken testów.
      PROMPT
    }
  ].freeze

  def self.fetch(name)
    const_name = name.to_s.upcase.tr("-", "_")
    const_get(const_name)
  rescue NameError
    raise ArgumentError, "Unknown plan: #{name.inspect}. Available: #{available.join(", ")}"
  end

  def self.available
    constants.map { |c| c.to_s.downcase.tr("_", "-") }
  end
end
