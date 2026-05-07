require "test_helper"

# Regression net for the chat-agent status-as-events refactor.
#
# Before the refactor, three event subscribers (instruction.requested,
# instruction.completed, instruction.failed) persisted "🌀 Building",
# "✅ Generation finished.", and "❌ ... failed." rows into `messages`. Those
# rows fed back into `chat.to_llm` as few-shot history and the LLM mimicked
# them on subsequent turns.
#
# This test asserts that after a full instrumented build cycle, none of those
# status strings appear in either the AR messages table or the message stream
# `chat.to_llm` would feed back to the model. If anyone re-introduces a
# subscriber-driven Message row carrying a status emoji, this test trips.
class ChatToLlmExcludesStatusTextTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  FORBIDDEN_SUBSTRINGS = [
    "🌀 Building",
    "✅ Generation finished",
    "❌"
  ].freeze

  setup do
    @user = create_user(openrouter_api_key: "sk-or-test-fixture-1234567890ab")
    @project = @user.projects.create!(name: "regression net")
    @chat = GeneratorAgent.create!(project: @project)
    @user_message = @chat.messages.create!(role: :user, content: "build x")
    @instruction = @project.instructions.create!(
      user_intent: "build x",
      description: "build x",
      phase: :implementing,
      anchor_message: @user_message
    )
  end

  test "instrumented build cycle inserts none of the legacy status strings into AR messages" do
    perform_enqueued_jobs(except: [ChatRespondJob, ExecuteInstructionJob, StopPreviewJob]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )

      @instruction.update!(phase: :completed)
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end

    contents = @chat.messages.pluck(:content).compact.join("\n")
    FORBIDDEN_SUBSTRINGS.each do |needle|
      refute_includes contents, needle,
        "AR messages must not contain #{needle.inspect} after the refactor"
    end
  end

  test "instrumented build cycle inserts none of the legacy status strings into chat.to_llm stream" do
    perform_enqueued_jobs(except: [ChatRespondJob, ExecuteInstructionJob, StopPreviewJob]) do
      ActiveSupport::Notifications.instrument(
        "instruction.requested",
        instruction_id: @instruction.id
      )

      @instruction.update!(phase: :completed)
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: @instruction.id
      )
    end

    llm_contents = @chat.to_llm.messages.map { |m| m.content.to_s }.join("\n")
    FORBIDDEN_SUBSTRINGS.each do |needle|
      refute_includes llm_contents, needle,
        "chat.to_llm must not feed #{needle.inspect} back to the model"
    end
  end

  test "instruction.failed path also produces no legacy status strings" do
    @instruction.revisions.create!(
      project: @project, position: 0, status: :failed,
      summary: "rev 0", prompt: "p"
    )
    @instruction.update!(phase: :failed)

    perform_enqueued_jobs(except: [ChatRespondJob, ExecuteInstructionJob, StopPreviewJob]) do
      ActiveSupport::Notifications.instrument(
        "instruction.failed",
        instruction_id: @instruction.id
      )
    end

    contents = @chat.messages.pluck(:content).compact.join("\n")
    FORBIDDEN_SUBSTRINGS.each do |needle|
      refute_includes contents, needle,
        "AR messages must not contain #{needle.inspect} on the failure path"
    end
  end
end
