class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  instructions

  tools do
    [
      StartGeneration.new(project: chat.project),
      SuggestPrompts.new(project: chat.project)
    ]
  end
end
