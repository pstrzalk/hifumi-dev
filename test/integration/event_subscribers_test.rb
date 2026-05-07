require "test_helper"

class EventSubscribersTest < ActiveSupport::TestCase
  include ActionCable::TestHelper
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Shop", user: users(:owner))
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "flower shop")
    @instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    2.times do |i|
      @instruction.revisions.create!(
        project: @project, position: i, status: :pending,
        summary: "rev #{i}", prompt: "p"
      )
    end
    @stream_name = @project.to_gid_param
  end

  test "instruction.requested broadcasts the revisions list partial to active_revisions" do
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end

  test "instruction.requested also enqueues ExecuteInstructionJob" do
    assert_enqueued_with(job: ExecuteInstructionJob, args: [ @instruction.id ]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end

  test "revision.started broadcasts a replace of the revision card" do
    revision = @instruction.revisions.first
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.started",
        revision_id: revision.id
      )
    end
  end

  test "revision.completed broadcasts a replace of the revision card" do
    revision = @instruction.revisions.first
    revision.update!(status: :completed, git_sha: "deadbee1234567")
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.completed",
        revision_id: revision.id,
        git_sha: revision.git_sha
      )
    end
  end

  test "revision.failed broadcasts a replace of the revision card" do
    revision = @instruction.revisions.first
    revision.update!(status: :failed)
    assert_broadcasts(@stream_name, 1) do
      ActiveSupport::Notifications.instrument(
        "revision.failed",
        revision_id: revision.id,
        error: "exit 1"
      )
    end
  end

  test "instruction.requested does not persist a 🌀 Building assistant message" do
    assert_no_difference -> { @chat.messages.where(role: :assistant).count } do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end

  test "instruction.completed does not persist any assistant status message" do
    assert_no_difference -> { @chat.messages.where(role: :assistant).count } do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end
  end

  test "instruction.completed broadcasts an appended status_row partial and an empty revisions list" do
    @instruction.update!(phase: :completed)
    perform_enqueued_jobs(except: ChatRespondJob) do
      assert_broadcasts(@stream_name, 2) do
        ActiveSupport::Notifications.instrument(
          "instruction.completed",
          instruction_id: @instruction.id
        )
      end
    end

    appended = broadcasts(@stream_name).find { |b| b.to_s.include?("✅ Built") }
    assert appended, "expected an append broadcast containing ✅ Built"
    assert_match(/target=\\?"messages\\?"/, appended.to_s)
    assert_match(/action=\\?"append\\?"/, appended.to_s)
  end

  test "instruction.completed persists a hidden synthetic nudge user message" do
    assert_difference -> { @chat.messages.where(system_injected: true).count }, 1 do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_equal "user", nudge.role
    assert_includes nudge.content, "Auto-resume"
    refute nudge.visible_in_chat?
  end

  test "instruction.completed enqueues a ChatRespondJob for the synthetic nudge" do
    assert_enqueued_jobs 1, only: ChatRespondJob do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    job = enqueued_jobs.find { |j| j["job_class"] == "ChatRespondJob" }
    assert_equal nudge.id, job["arguments"].first
  end

  test "instruction.completed lists pending mid-build user messages in the nudge body" do
    @chat.messages.create!(role: :user, content: "make the banner green")
    @chat.messages.create!(role: :user, content: "and add a logo")

    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: @instruction.id
    )

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_includes nudge.content, "make the banner green"
    assert_includes nudge.content, "and add a logo"
  end

  test "instruction.completed includes a 'no messages' marker when none were sent during the build" do
    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: @instruction.id
    )

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_match(/no messages were sent/, nudge.content)
  end

  test "instruction.completed nudge body forbids past-tense completion claims and requires a question" do
    ActiveSupport::Notifications.instrument(
      "instruction.completed",
      instruction_id: @instruction.id
    )

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_match(/Do NOT use past-tense completion language/, nudge.content)
    assert_match(/END with a question/, nudge.content)
    %w[Done Built Finished Updated Applied].each do |word|
      assert_includes nudge.content, %("#{word}"), "expected branch 2 to forbid the word #{word.inspect}"
    end
  end

  test "instruction.failed broadcasts a status_row partial naming the failing revision" do
    @instruction.update!(phase: :failed)
    failing = @instruction.revisions.first
    failing.update!(status: :failed)

    perform_enqueued_jobs(except: ChatRespondJob) do
      ActiveSupport::Notifications.instrument(
        "instruction.failed",
        instruction_id: @instruction.id
      )
    end

    appended = broadcasts(@stream_name).find { |b| b.to_s.include?("Build failed") }
    assert appended, "expected an append broadcast containing Build failed"
    assert_includes appended.to_s, "❌ Build failed: rev 0"
    assert_match(/target=\\?"messages\\?"/, appended.to_s)
    assert_match(/action=\\?"append\\?"/, appended.to_s)
  end

  test "instruction.failed falls back to generic content if no revision is in failed status" do
    @instruction.update!(phase: :failed)

    perform_enqueued_jobs(except: ChatRespondJob) do
      ActiveSupport::Notifications.instrument(
        "instruction.failed",
        instruction_id: @instruction.id
      )
    end

    appended = broadcasts(@stream_name).find { |b| b.to_s.include?("Build failed") }
    assert appended, "expected an append broadcast containing Build failed"
    assert_includes appended.to_s, "❌ Build failed"
    refute_match(/Build failed:/, appended.to_s)
  end
end
