# Routes ActiveSupport::Notifications to downstream side-effects:
# job enqueues, Turbo broadcasts, follow-up jobs.
#
# Subscribers MUST only enqueue jobs or broadcast Turbo Streams. No business
# logic here — that lives in the tool/job handlers.

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  ExecuteInstructionJob.perform_later(payload[:instruction_id])
end

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: instruction.revisions.order(:position) }
  )
end

# Auto-stop the preview as soon as a new instruction starts: production-mode
# containers don't autoload, so a running preview shows stale code mid-
# generation regardless of whether we'd kept it up. Stopping here also frees
# the bind-mounted SQLite for migrations the agent may run during the build.
ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  StopPreviewJob.perform_later(instruction.project.id)
end

# After the LLM has just called create_application/modify_application, the
# user needs an immediate "build started" indicator. The LLM itself is forbidden
# (per the agent prompt) from narrating around the tool call — so we post the
# starting message here, symmetric to "✅ Generation finished." on completion.
ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  instruction.project.chat.messages.create!(
    role: :assistant,
    content: "🌀 Building: #{instruction.description}"
  )
end

%w[revision.started revision.completed revision.failed].each do |event|
  ActiveSupport::Notifications.subscribe(event) do |*, payload|
    revision = Revision.find(payload[:revision_id])
    Turbo::StreamsChannel.broadcast_replace_to(
      revision.project,
      target: ActionView::RecordIdentifier.dom_id(revision),
      partial: "revisions/revision",
      locals: { revision: revision }
    )
  end
end

ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  instruction.project.chat.messages.create!(
    role: :assistant,
    content: "✅ Generation finished."
  )
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end

ActiveSupport::Notifications.subscribe("instruction.failed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  failed = instruction.revisions.where(status: :failed).order(:position).first
  content = failed ?
    "❌ Revision '#{failed.summary}' failed." :
    "❌ Generation failed."
  instruction.project.chat.messages.create!(role: :assistant, content: content)
  Turbo::StreamsChannel.broadcast_replace_to(
    instruction.project,
    target: "active_revisions",
    partial: "revisions/list",
    locals: { revisions: [] }
  )
end
