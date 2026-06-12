class GeneratorAgent < RubyLLM::Agent
  # Creation-time default only — ChatRespondJob re-applies the project's
  # chat_model selection (via with_model) on every turn.
  model LLM::Stages.find(:chat).default_model
  chat_model Chat
  instructions { prompt("instructions", current_state: chat.project.current_state_prompt) }

  tools do
    project = chat.project
    mutation_tool = if project.workspace_initialized?
      ModifyApplication.new(project: project)
    else
      CreateApplication.new(project: project)
    end
    [ mutation_tool ]
  end
end
