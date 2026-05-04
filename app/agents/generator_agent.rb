class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  instructions { prompt("instructions", current_state: chat.project.current_state_prompt) }

  tools do
    [
      CreateApplication.new(project: chat.project),
      SuggestPrompts.new(project: chat.project)
    ]
  end
end
