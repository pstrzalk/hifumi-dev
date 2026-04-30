class StartGeneration < RubyLLM::Tool
  def name = "start_generation"
  description "Starts application generation. Call when the user has described what they want to build and you have any clarifications you need."

  params do
    string :intent,
           description: "Plain-language description of what the user wants, e.g. 'flower shop with inventory and Stripe'."
    object :clarifications,
           description: "Answers to clarifying questions, as key-value pairs. Empty object if none." do
      additional_properties true
    end
  end

  def initialize(project:)
    super()
    @project = project
  end

  def execute(intent:, clarifications: {})
    if @project.instructions.where.not(phase: %w[completed failed cancelled]).exists?
      return {
        error: "A generation is already in progress. Tell the user you'll start their next change once the current build finishes."
      }
    end

    result = CreatePlan.call(
      intent: intent,
      clarifications: clarifications,
      context: { project_id: @project.id },
      openrouter_api_key: @project.user.profile.openrouter_api_key
    )

    instruction = nil
    ActiveRecord::Base.transaction do
      instruction = @project.instructions.create!(
        user_intent: intent,
        description: result.instruction_description,
        phase: :implementing,
        anchor_message: anchor_message
      )

      previous = nil
      result.revisions.each_with_index do |r, i|
        previous = instruction.revisions.create!(
          project: @project,
          summary: r[:summary],
          prompt: r[:prompt],
          position: i,
          status: :pending,
          parent: previous
        )
      end
    end

    ActiveSupport::Notifications.instrument(
      "instruction.requested",
      instruction_id: instruction.id
    )

    {
      instruction_id: instruction.id,
      revision_count: result.revisions.size,
      instruction_description: result.instruction_description
    }
  rescue CreatePlan::AdHocLLM::InvalidResponse => e
    { error: "Could not generate a plan: #{e.message}. Ask the user to rephrase." }
  end

  private

  def anchor_message
    @project.chat.messages.where(role: :user).order(:id).last
  end
end
