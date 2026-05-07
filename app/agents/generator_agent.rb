class GeneratorAgent < RubyLLM::Agent
  model "anthropic/claude-haiku-4.5"
  chat_model Chat
  instructions { prompt("instructions", current_state: chat.project.current_state_prompt) }

  tools do
    project = chat.project
    mutation_tool = if project.workspace_initialized?
      ModifyApplication.new(project: project)
    else
      CreateApplication.new(project: project)
    end
    [mutation_tool]
  end
end
