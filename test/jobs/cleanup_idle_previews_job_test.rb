require "test_helper"

class CleanupIdlePreviewsJobTest < ActiveJob::TestCase
  test "uses :preview queue" do
    assert_enqueued_with(job: CleanupIdlePreviewsJob, queue: "preview") do
      CleanupIdlePreviewsJob.perform_later
    end
  end

  test "enqueues StopPreviewJob for previews running longer than IDLE_TIMEOUT" do
    project = Project.create!(name: "Idle Preview")
    project.update!(preview_state: :running, preview_started_at: 31.minutes.ago)

    assert_enqueued_with(job: StopPreviewJob, args: [project.id], queue: "preview") do
      CleanupIdlePreviewsJob.perform_now
    end
  end

  test "does not enqueue StopPreviewJob for previews started within IDLE_TIMEOUT" do
    project = Project.create!(name: "Fresh Preview")
    project.update!(preview_state: :running, preview_started_at: 1.minute.ago)

    assert_no_enqueued_jobs(only: StopPreviewJob) do
      CleanupIdlePreviewsJob.perform_now
    end
  end

  test "does not enqueue StopPreviewJob for stopped previews regardless of age" do
    project = Project.create!(name: "Stopped Preview")
    project.update!(preview_state: :stopped, preview_started_at: 2.hours.ago)

    assert_no_enqueued_jobs(only: StopPreviewJob) do
      CleanupIdlePreviewsJob.perform_now
    end
  end
end
