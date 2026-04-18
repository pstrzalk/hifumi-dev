# typed: true
# frozen_string_literal: true

#: self as Roast::Workflow

# Minimal test: cmd + ruby + data passing
# Run: bundle exec roast test_basic.rb

config do
  cmd { display! }
end

execute do
  cmd(:hello) { "echo 'Hello from Roast'" }

  ruby(:process) do
    text = cmd!(:hello).text
    puts "Ruby cog received: #{text}"
    { original: text, upper: text.upcase, length: text.length }
  end

  cmd(:result) do |my|
    data = ruby!(:process).value
    my.command = "echo"
    my.args = ["Processed: #{data[:upper]} (#{data[:length]} chars)"]
  end
end
