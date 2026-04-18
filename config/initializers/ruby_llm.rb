RubyLLM.configure do |config|
  config.openrouter_api_key = ENV.fetch("OPENROUTER_API_KEY", Rails.application.credentials.dig(:openrouter_api_key))
  config.default_model = "anthropic/claude-haiku-4.5"

  # Use the new association-based acts_as API (recommended)
  config.use_new_acts_as = true
end
