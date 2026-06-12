module PlanApplicationCreation
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/plan_application_creation_system.md").read.freeze

    class InvalidResponse < StandardError; end

    def self.call(intent:, clarifications:, context:, openrouter_api_key:, model:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      content = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt, openrouter_api_key: openrouter_api_key, model: model)
      build_result(content)
    end

    def self.invoke_llm(system:, user:, openrouter_api_key:, model:)
      ctx = RubyLLM.context { |c| c.openrouter_api_key = openrouter_api_key }
      chat = ctx.chat(model: model)
      chat.with_instructions(system)
      chat.with_schema(PlanSchema).ask(user).content
    end

    def self.build_user_prompt(intent, clarifications, _context)
      lines = [ "Intent: #{intent}" ]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      lines.join("\n")
    end

    def self.build_result(content)
      raise InvalidResponse, "LLM returned no content" if content.nil?

      revisions = Array(content["revisions"]).map do |r|
        { summary: r.fetch("summary"), prompt: r.fetch("prompt") }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?

      PlanApplicationCreation::Result.new(
        instruction_description: content.fetch("instruction_description"),
        revisions: revisions
      )
    rescue KeyError => e
      raise InvalidResponse, "plan missing field: #{e.message}"
    end
  end
end
