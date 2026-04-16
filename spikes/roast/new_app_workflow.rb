# frozen_string_literal: true

# W1: Generowanie nowej aplikacji (uproszczone do spike'a)
# Tworzy Rails app od zera i wykonuje rewizje
#
# Uruchomienie:
#   bin/roast execute new_app_workflow.rb -- \
#     --app-name flower-shop \
#     --workspace /tmp \
#     --prompt "Aplikacja do sprzedaży kwiatów. Klient przegląda bukiety, dodaje do koszyka, składa zamówienie z adresem dostawy."

config do
  agent do
    provider :claude
    model "sonnet"
  end

  chat(:planner) do
    provider :anthropic
    model "claude-sonnet-4-20250514"
  end

  cmd do
    display!
  end

  map(:revisions) do
    parallel 1 # Sekwencyjnie — każda rewizja buduje na poprzedniej
  end
end

# --- Scope: wykonanie jednej rewizji (W2 uproszczone) ---

execute(:execute_revision) do
  # Implement
  agent(:generate) do |_, revision|
    workspace = kwarg(:workspace_path)
    <<~PROMPT
      ## Zadanie
      #{revision[:prompt]}

      ## Zasady
      - Rails Way: konwencje, generatory, wbudowane rozwiązania
      - Tailwind CSS, Hotwire (Turbo + Stimulus)
      - SQLite, Solid Queue/Cable/Cache
      - Minitest, nie RSpec
      - Pisz testy
    PROMPT
  end

  # Verify
  ruby(:verify) do
    workspace = kwarg(:workspace_path)
    errors = []

    result = `cd #{workspace} && bundle check 2>&1`
    errors << "bundle check:\n#{result}" unless $?.success?

    result = `cd #{workspace} && bin/rails db:prepare 2>&1`
    errors << "db:prepare:\n#{result}" unless $?.success?

    result = `cd #{workspace} && bin/rails runner "puts :ok" 2>&1`
    errors << "boot check:\n#{result}" unless $?.success?

    test_files = Dir.glob("#{workspace}/test/**/*_test.rb")
    if test_files.any?
      result = `cd #{workspace} && bin/rails test 2>&1`
      errors << "rails test:\n#{result}" unless $?.success?
    end

    if errors.any?
      fail!(errors.join("\n\n"))
    end

    "all checks passed"
  end

  # Commit
  cmd(:commit) do |my, revision|
    workspace = kwarg(:workspace_path)
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && git add -A && git commit -m '#{revision[:summary]}'"]
  end
end

# --- Main workflow ---

execute do
  # W1.1: Rails new
  cmd(:rails_new) do |my|
    app_name = kwarg(:app_name)
    workspace = kwarg(:workspace)
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && rails new #{app_name} --css tailwind --database sqlite3 --skip-jbuilder --skip-test-unit"]
  end

  # Zapisz workspace path
  ruby(:set_workspace) do
    path = File.join(kwarg(:workspace), kwarg(:app_name))
    # Ustaw jako kwarg dla dalszych kroków
    metadata[:workspace_path] = path
    path
  end

  # Git init (rails new robi to automatycznie, ale upewnijmy się)
  cmd(:git_init) do |my|
    workspace = ruby!(:set_workspace).value
    my.command = "sh"
    my.args = ["-c", "cd #{workspace} && git add -A && git commit -m 'Initial Rails app' --allow-empty"]
  end

  # W1.3: Plan — LLM generuje listę rewizji
  chat(:plan) do
    <<~PROMPT
      Jesteś planistą aplikacji Rails. Na podstawie opisu wygeneruj plan implementacji
      jako listę kroków (rewizji). Każdy krok powinien być atomowy i testowalny.

      Opis aplikacji: #{kwarg(:prompt)}

      Odpowiedz jako JSON array obiektów z polami:
      - "summary": krótki opis kroku (do git commit message)
      - "prompt": szczegółowy opis co zrobić w tym kroku

      Zasady:
      - Krok 1: modele i migracje (fundamenty)
      - Krok 2: kontrolery i routing
      - Krok 3: widoki (Tailwind + Hotwire)
      - Krok 4: testy
      - Max 4-5 kroków dla prostej aplikacji
      - Każdy krok musi dać działającą aplikację (nie zostawiaj broken state)

      Odpowiedz TYLKO JSONem, bez markdown code blocks.
    PROMPT
  end

  # Parse plan
  ruby(:parse_plan) do
    require "json"
    raw = chat!(:plan).text
    # Wyciągnij JSON z odpowiedzi (na wypadek gdyby LLM dodał tekst dookoła)
    json_match = raw.match(/\[.*\]/m)
    fail!("Plan nie zawiera JSON array") unless json_match
    JSON.parse(json_match[0], symbolize_names: true)
  end

  # W1.5: Wykonaj rewizje
  map(:build, run: :execute_revision) do |my|
    my.items = ruby!(:parse_plan).value
  end

  # Raport
  ruby(:report) do
    workspace = ruby!(:set_workspace).value
    log = `cd #{workspace} && git log --oneline 2>&1`
    puts "\n=== Generowanie zakończone ==="
    puts "Workspace: #{workspace}"
    puts "Git log:\n#{log}"
    { workspace: workspace, status: :completed }
  end
end
