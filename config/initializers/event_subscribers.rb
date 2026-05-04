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

# After every completed instruction, fire one LLM turn to recap and ask the
# user what's next. The LLM is forbidden (via the synthetic nudge body) from
# calling any tool — its job is text-only summary + question. The user's
# next reply re-enters the normal confirmation flow.
#
# This is how mid-build user messages get surfaced for explicit confirmation
# rather than being silently dropped.
ActiveSupport::Notifications.subscribe("instruction.completed") do |*, payload|
  instruction = Instruction.find(payload[:instruction_id])
  chat = instruction.project.chat

  pending = chat.messages
    .where(role: :user, system_injected: false)
    .where("id > ?", instruction.anchor_message_id)
    .order(:id)

  pending_section = if pending.empty?
    "(no messages were sent during the build.)"
  else
    pending.map { |m| "- #{m.content}" }.join("\n")
  end

  nudge_body = <<~NUDGE
    [Auto-resume after instruction ##{instruction.id} completed.]

    Messages the user sent while the build was running:
    #{pending_section}

    Your job in this turn:
    1. If the user sent change requests during the build, recap them in 1-2 sentences and ask whether to proceed (without applying anything yet).
    2. If they sent no change requests (or only questions), acknowledge that the build finished and ask what they want next.
    3. DO NOT call create_application or modify_application. DO NOT call any other tool. Reply with text only.
  NUDGE

  nudge_msg = chat.messages.create!(
    role: :user,
    content: nudge_body,
    system_injected: true
  )

  ChatRespondJob.perform_later(nudge_msg.id)
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
