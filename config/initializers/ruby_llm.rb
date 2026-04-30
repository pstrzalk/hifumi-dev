RubyLLM.configure do |config|
  # RubyLLM eagerly validates provider config when a Chat is constructed
  # (provider.rb#initialize → ensure_configured!), which happens during
  # GeneratorAgent.create!. A nil key would crash that eager check before
  # the per-user key gets threaded via RubyLLM.context.
  #
  # Dev/test use ENV["OPENROUTER_API_KEY"] (set in .env). Production never
  # sets that ENV — the per-user key from project.user.profile.openrouter_api_key
  # is applied via with_context inside ChatRespondJob. The placeholder below
  # exists only to satisfy the eager validation; if a code path forgets to
  # thread the context, OpenRouter rejects it with 401 (auth fail), so the
  # deployer's wallet is never charged.
  config.openrouter_api_key = ENV["OPENROUTER_API_KEY"].presence ||
                              "placeholder-overridden-per-user-via-with_context"
  config.default_model = "anthropic/claude-haiku-4.5"
  config.use_new_acts_as = true
end
