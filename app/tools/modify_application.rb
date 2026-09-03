class ModifyApplication < RubyLLM::Tool
  def name = "modify_application"
  description "Modifies the existing application based on the user's change request. " \
              "Call this when the project already has a generated application and the user wants a change. " \
              "The user must have explicitly confirmed they're ready to apply the change before you call this."

  parameters do
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
      # Built here rather than in the planner so AdHocLLM stays a pure function
      # of its arguments, and so the file reads sit inside the rescue below —
      # ENOENT/EACCES on a workspace file degrades to a chat-safe error hash
      # instead of orphaning the tool_use.
      context: { app_state: AppState.build(workspace: @project.workspace_path) },
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
  rescue PlanApplicationModification::AdHocLLM::InvalidResponse, JSON::ParserError => e
    # JSON::ParserError: v2's Message#parsed raises on a malformed plan where v1
    # silently kept the String. Nothing may escape #execute — an exception here
    # leaves a persisted tool_use with no tool_result and the chat is finished.
    { error: "Could not generate a modification plan: #{e.message}. Ask the user to rephrase." }
  rescue StandardError => e
    # Backstop for the same invariant. A rescue list cannot be complete: the
    # revisions loop can raise NoMethodError/TypeError on an off-schema plan,
    # and `revisions.create!` can raise RecordInvalid on a blank summary or
    # prompt. RubyLLM's own orphan cleanup does not cover any of these — it
    # only fires for RubyLLM/Faraday/Timeout errors — so anything reaching
    # here would kill the chat permanently. Report it rather than swallow it.
    Rails.error.report(e, handled: true, context: { project_id: @project.id })
    { error: "Could not generate a modification plan. Ask the user to rephrase." }
  end

  private

  def anchor_message
    @project.chat.messages.where(role: :user).order(:id).last
  end
end
