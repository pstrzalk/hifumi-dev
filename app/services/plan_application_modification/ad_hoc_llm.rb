module PlanApplicationModification
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/plan_application_modification_system.md").read.freeze

    class InvalidResponse < StandardError; end

    # Appended when there is no snapshot to give (a --blind probe, or a workspace
    # gone between the tool being bound and the call). The system prompt tells
    # the planner the state is given and forbids hedging; this is the one place
    # that claim is false, so say so where the model reads it.
    NO_STATE_NOTE = "No application state snapshot is available for this request. " \
                    "Say what you assume about existing files, tables and colours instead of asserting it."

    def self.call(intent:, clarifications:, context:, openrouter_api_key:, model:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      content = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt, openrouter_api_key: openrouter_api_key, model: model)
      build_result(content)
    end

    def self.invoke_llm(system:, user:, openrouter_api_key:, model:)
      ctx = RubyLLM.context { |c| c.openrouter_api_key = openrouter_api_key }
      chat = ctx.chat(model: model)
      chat.with_instructions(system)
      chat.with_schema(PlanSchema).ask(user).parsed
    end

    # The first deliberate divergence from the PlanApplicationCreation twin,
    # which cannot have workspace context: the workspace does not exist when
    # it runs (CreateApplication persists the plan before ExecuteInstructionJob
    # runs `rails new`).
    def self.build_user_prompt(intent, clarifications, context)
      lines = [ "Intent: #{intent}" ]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      # Last, matching RevisionPrompt.build, which leads with "## Task" and only
      # then appends the stack inventory, the docs manifest and the workspace
      # snapshot: request first, reference material after. Keeps the ask from
      # being buried behind up to ~35 KB of listing (project_39, the largest). (There is no schema text in
      # this turn to sit next to — with_schema ships as OpenRouter's
      # `response_format` payload field.)
      app_state = context.is_a?(Hash) ? context[:app_state] : nil
      lines << "\n#{app_state.presence || NO_STATE_NOTE}"
      lines.join("\n")
    end

    def self.build_result(content)
      raise InvalidResponse, "LLM returned no content" if content.nil?
      # Message#parsed is JSON.parse: valid JSON that isn't an object gets
      # through it, and `Array(array_or_number["revisions"])` then raises
      # TypeError — which ModifyApplication#execute does not rescue, leaving a
      # persisted tool_use with no tool_result and a permanently dead chat.
      raise InvalidResponse, "expected a JSON object, got #{content.class}" unless content.is_a?(Hash)

      revisions = Array(content["revisions"]).map do |r|
        # The Hash check above only covers the top level. A valid JSON object
        # whose `revisions` hold non-objects raises NoMethodError (String#fetch)
        # or TypeError (Array#fetch, via Array(hash) => [[k, v]]) here — neither
        # of which #execute rescues, and both of which orphan the tool_use.
        raise InvalidResponse, "expected revision objects, got #{r.class}" unless r.is_a?(Hash)

        { summary: r.fetch("summary"), prompt: r.fetch("prompt") }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?

      PlanApplicationModification::Result.new(
        instruction_description: content.fetch("instruction_description"),
        revisions: revisions
      )
    rescue KeyError => e
      raise InvalidResponse, "plan missing field: #{e.message}"
    end
  end
end
