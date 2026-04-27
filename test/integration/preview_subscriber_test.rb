require "test_helper"

class PreviewSubscriberTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @project = Project.create!(name: "Preview Sub Test")
    @chat = @project.create_chat!
    @msg = @chat.messages.create!(role: :user, content: "hi")
    @instruction = @project.instructions.create!(
      anchor_message: @msg,
      description: "x",
      user_intent: "x",
      phase: :implementing
    )
  end

  test "instruction.requested enqueues StopPreviewJob for the project" do
    assert_enqueued_with(job: StopPreviewJob, args: [@project.id]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end

  test "instruction.requested still enqueues ExecuteInstructionJob (existing subscriber not regressed)" do
    assert_enqueued_with(job: ExecuteInstructionJob, args: [@instruction.id]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )
    end
  end
end
