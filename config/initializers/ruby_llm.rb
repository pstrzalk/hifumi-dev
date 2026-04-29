RubyLLM.configure do |config|
  # Default key for dev/test convenience. Production unsets the ENV — every
  # request uses project.user.profile.openrouter_api_key via with_context.
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"]
  config.default_model = "anthropic/claude-haiku-4.5"
  config.use_new_acts_as = true
end
