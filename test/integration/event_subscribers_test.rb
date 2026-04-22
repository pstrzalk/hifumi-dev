require "test_helper"

class EventSubscribersTest < ActiveSupport::TestCase
  include ActionCable::TestHelper
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Shop")
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
    perform_enqueued_jobs do
      assert_broadcasts(@stream_name, 2) do
        ActiveSupport::Notifications.instrument(
          "instruction.completed",
          instruction_id: @instruction.id
        )
      end
    end
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
