require "test_helper"

class InstructionTest < ActiveSupport::TestCase
  test "valid fixture loads" do
    assert instructions(:flowers_v1).valid?
  end

  test "phase defaults to researching" do
    instruction = Instruction.new(
      project: projects(:flowers),
      anchor_message: messages(:create_application),
      description: "New feature"
    )
    assert_equal "researching", instruction.phase
    assert instruction.valid?
  end

  test "phase accepts every enum value" do
    instruction = instructions(:flowers_v1)
    %w[researching planning implementing completed failed cancelled].each do |phase|
      instruction.phase = phase
      assert instruction.valid?, "expected phase #{phase} to be valid"
    end
  end

  test "phase rejects unknown value" do
    instruction = instructions(:flowers_v1)
    instruction.phase = "bogus"
    assert_not instruction.valid?
    assert_includes instruction.errors[:phase], "is not included in the list"
  end

  test "requires description and anchor_message" do
    instruction = Instruction.new(project: projects(:flowers))
    assert_not instruction.valid?
    assert_includes instruction.errors[:description], "can't be blank"
    assert_includes instruction.errors[:anchor_message], "must exist"
  end

  test "destroying instruction cascades to revisions" do
    assert_difference -> { Revision.count } => -2 do
      instructions(:flowers_v1).destroy!
    end
  end

  test "user_intent is optional" do
    instruction = Instruction.new(
      project: projects(:flowers),
      anchor_message: messages(:create_application),
      description: "Plan without recorded user intent"
    )
    assert_nil instruction.user_intent
    assert instruction.valid?
  end

  test "terminal? is true for completed, failed, and cancelled phases" do
    instruction = instructions(:flowers_v1)
    %w[completed failed cancelled].each do |phase|
      instruction.phase = phase
      assert instruction.terminal?, "expected phase #{phase} to be terminal"
    end
  end

  test "terminal? is false for researching, planning, and implementing phases" do
    instruction = instructions(:flowers_v1)
    %w[researching planning implementing].each do |phase|
      instruction.phase = phase
      assert_not instruction.terminal?, "expected phase #{phase} to not be terminal"
    end
  end

  test "saving an instruction touches its project (bumps active timestamp)" do
    instruction = instructions(:flowers_v1)
    project = instruction.project
    travel_to 1.hour.from_now do
      assert_changes -> { project.reload.updated_at } do
        instruction.update!(phase: :completed)
      end
    end
  end
end
