# frozen_string_literal: true

# Deterministic three-revision plan used by the integration test and by
# `bin/generate full`. Mirrors the spike's Plans::TODO_LIST so we can exercise
# W2 end-to-end without burning chat-LLM or plan-LLM tokens.
#
# Reference: spikes/roast/plans.rb

module PlanFixtures
  def self.todo_list
    CreatePlan::Result.new(
      instruction_description: "Build a Tailwind-styled CRUD todo list (model, controller, views).",
      revisions: [
        {
          summary: "Add Todo model with title, body, done, category",
          prompt: <<~PROMPT
            Create a Todo model with fields:
            - title (string, required)
            - body (text, optional)
            - done (boolean, default false)
            - category (string, optional)

            Requirements:
            - Migration with appropriate types and indexes
            - Validations in the model (title required, minimum length 1)
            - Fixtures in test/fixtures/todos.yml (at least 2 records)
            - Model test in test/models/todo_test.rb (validation test)
            - Run `bin/rails db:migrate` after creating the migration

            Do not add controllers or views — that's the next step.
          PROMPT
        },
        {
          summary: "Add TodosController with index/show/new/create/edit/update/destroy",
          prompt: <<~PROMPT
            Create a full REST controller TodosController with actions: index, show, new, create, edit, update, destroy.

            Requirements:
            - `resources :todos` in config/routes.rb
            - Strong parameters (title, body, done, category)
            - Flash messages after create/update/destroy
            - Redirects after mutations (to index or show)
            - Controller test in test/controllers/todos_controller_test.rb covering all actions
            - Do not create views yet — index/show/new/edit may return empty HTML for now
            - All controller tests must pass (bin/rails test)

            Root route can stay as it was — do not change `root`.
          PROMPT
        },
        {
          summary: "Add Tailwind views for Todo with Hotwire Turbo",
          prompt: <<~PROMPT
            Add Tailwind views for Todo with Hotwire Turbo Frames and Turbo Streams.

            Requirements:
            - app/views/todos/index.html.erb — list of todos in a table or cards, styled with Tailwind
            - app/views/todos/show.html.erb — details with edit/destroy links
            - app/views/todos/new.html.erb + edit.html.erb — forms (shared _form partial)
            - app/views/todos/_todo.html.erb partial — one todo item
            - Turbo Frame `dom_id(@todo)` for optimistic updates
            - "done" checkbox toggles via Turbo Stream (optional — if easy)
            - Status badge: green "Done" vs gray "Todo"
            - Working navigation header with a link to /todos
            - Root route to TodosController#index (change config/routes.rb)
            - Controller tests must still pass

            Do not install new gems. Use what's there (Tailwind, Turbo installed via `rails new --css tailwind`).
          PROMPT
        }
      ]
    )
  end
end
