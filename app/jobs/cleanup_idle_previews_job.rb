class CleanupIdlePreviewsJob < ApplicationJob
  queue_as :preview

  # PoC interpretation: "idle" = "running for >30 min", regardless of last
  # access. We don't track iframe activity yet; revisit if users complain
  # about active previews getting reaped.
  IDLE_TIMEOUT = 30.minutes

  def perform
    Project.where(preview_state: :running)
           .where("preview_started_at < ?", IDLE_TIMEOUT.ago)
           .find_each { |project| StopPreviewJob.perform_later(project.id) }
  end
end
