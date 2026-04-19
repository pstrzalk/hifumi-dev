# Routes ActiveSupport::Notifications to downstream side-effects:
# job enqueues, Turbo broadcasts, follow-up jobs.
#
# Subscribers MUST only enqueue jobs or broadcast Turbo Streams. No business
# logic here — that lives in the tool/job handlers.
#
# Step 5 owns: instruction.requested → ExecuteInstructionJob.
# Step 6 adds: revision.* Turbo broadcasts + instruction.{completed,failed}
#            → ChatFollowUpJob.

ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
  ExecuteInstructionJob.perform_later(payload[:instruction_id])
end
