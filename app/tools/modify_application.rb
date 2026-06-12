class ModifyApplication < RubyLLM::Tool
  def name = "modify_application"
  description "Modifies the existing application based on the user's change request. " \
              "Call this when the project already has a generated application and the user wants a change. " \
              "The user must have explicitly confirmed they're ready to apply the change before you call this."

  params do
    string :intent,
           description: "Plain-language description of the change the user wants, e.g. 'make the primary color teal'."
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

    result = PlanApplicationModification.call(
      intent: intent,
      clarifications: clarifications,
      context: { project_id: @project.id },
      openrouter_api_key: @project.user.profile.openrouter_api_key,
      model: @project.plan_modification_model
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
  rescue PlanApplicationModification::AdHocLLM::InvalidResponse => e
    { error: "Could not generate a modification plan: #{e.message}. Ask the user to rephrase." }
  end

  private

  def anchor_message
    @project.chat.messages.where(role: :user).order(:id).last
  end
end
