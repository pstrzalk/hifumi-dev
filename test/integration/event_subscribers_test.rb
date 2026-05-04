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

  test "instruction.requested persists a 🌀 Building assistant message" do
    assert_difference -> { @chat.messages.where(role: :assistant).count }, 1 do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end

    msg = @chat.messages.where(role: :assistant).order(:id).last
    assert_match(/^🌀 Building: /, msg.content)
    assert_includes msg.content, @instruction.description
  end

  test "instruction.completed persists an assistant status message" do
    assert_difference -> { @chat.messages.where(role: :assistant).count }, 1 do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end

    msg = @chat.messages.where(role: :assistant).last
    assert_equal "✅ Generation finished.", msg.content
  end

  test "instruction.completed broadcasts both the status message and an empty list" do
    # Drains only the Turbo broadcast jobs from `broadcast_append_later_to` for
    # the persisted assistant message — explicitly skips ChatRespondJob (the
    # auto-recap subscriber's enqueue), which would otherwise also fire and
    # send a chat_notice broadcast on top of the two we care about here.
    perform_enqueued_jobs(except: ChatRespondJob) do
      assert_broadcasts(@stream_name, 2) do
        ActiveSupport::Notifications.instrument(
          "instruction.completed",
          instruction_id: @instruction.id
        )
      end
    end
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

  test "instruction.failed names the failing revision in the status message" do
    failing = @instruction.revisions.first
    failing.update!(status: :failed)

    ActiveSupport::Notifications.instrument(
      "instruction.failed",
      instruction_id: @instruction.id
    )

    msg = @chat.messages.where(role: :assistant).last
    assert_equal "❌ Revision 'rev 0' failed.", msg.content
  end

  test "instruction.failed falls back to generic content if no revision is in failed status" do
    ActiveSupport::Notifications.instrument(
      "instruction.failed",
      instruction_id: @instruction.id
    )

    msg = @chat.messages.where(role: :assistant).last
    assert_equal "❌ Generation failed.", msg.content
  end
end
