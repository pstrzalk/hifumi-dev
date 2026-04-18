require "test_helper"

class InstructionTest < ActiveSupport::TestCase
  test "valid fixture loads" do
    assert instructions(:flowers_v1).valid?
  end

  test "phase defaults to researching" do
    instruction = Instruction.new(
      project: projects(:flowers),
      anchor_message: messages(:start_generation),
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
      anchor_message: messages(:start_generation),
      description: "Plan without recorded user intent"
    )
    assert_nil instruction.user_intent
    assert instruction.valid?
  end
end
