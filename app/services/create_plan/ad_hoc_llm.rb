module CreatePlan
  module AdHocLLM
    SYSTEM_PROMPT = Rails.root.join("app/prompts/create_plan_system.md").read.freeze
    MODEL = "anthropic/claude-haiku-4.5"

    class InvalidResponse < StandardError; end

    class EmitPlan < RubyLLM::Tool
      def name = "emit_plan"
      description "Emit the application-generation plan. Call this exactly once with the complete plan."

      params do
        string :instruction_description,
               description: "One-sentence human description of the whole plan."
        array :revisions,
              description: "Ordered list of 3 to 6 atomic revisions." do
          object do
            string :summary, description: "Git-commit-style one-liner summarising this revision."
            string :prompt, description: "Concrete, file-level instruction passed to the implementer agent."
          end
        end
      end

      attr_reader :captured

      def execute(instruction_description:, revisions:)
        @captured = { instruction_description: instruction_description, revisions: revisions }
        halt({ ok: true })
      end
    end

    def self.call(intent:, clarifications:, context:)
      user_prompt = build_user_prompt(intent, clarifications, context)
      tool = invoke_llm(system: SYSTEM_PROMPT, user: user_prompt)
      build_result(tool.captured)
    end

    def self.invoke_llm(system:, user:)
      tool = EmitPlan.new
      chat = RubyLLM.chat(model: MODEL)
      chat.with_instructions(system)
      chat.with_tool(tool, choice: :required)
      chat.ask(user)
      tool
    end

    def self.build_user_prompt(intent, clarifications, _context)
      lines = ["Intent: #{intent}"]
      if clarifications.present?
        lines << "Clarifications:"
        clarifications.each { |k, v| lines << "  - #{k}: #{v}" }
      end
      lines.join("\n")
    end

    def self.build_result(captured)
      raise InvalidResponse, "LLM did not call emit_plan" if captured.nil?

      revisions = Array(captured[:revisions]).map do |r|
        { summary: fetch_any(r, :summary), prompt: fetch_any(r, :prompt) }
      end
      raise InvalidResponse, "empty revisions" if revisions.empty?

      CreatePlan::Result.new(
        instruction_description: captured.fetch(:instruction_description),
        revisions: revisions
      )
    rescue KeyError => e
      raise InvalidResponse, "plan missing field: #{e.message}"
    end

    # RubyLLM normalises top-level tool args to symbols but leaves nested hashes
    # with string keys (JSON.parse default). Look up under either.
    def self.fetch_any(hash, key)
      hash.fetch(key) { hash.fetch(key.to_s) }
    end
  end
end
