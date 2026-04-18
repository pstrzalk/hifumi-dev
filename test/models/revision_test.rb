require "test_helper"

class RevisionTest < ActiveSupport::TestCase
  test "valid fixtures load" do
    assert revisions(:flowers_v1_step1).valid?
    assert revisions(:flowers_v1_step2).valid?
  end

  test "status defaults to pending" do
    revision = Revision.new(
      project: projects(:flowers),
      instruction: instructions(:flowers_v1),
      position: 99,
      summary: "New step",
      prompt: "Add a new step to the plan."
    )
    assert_equal "pending", revision.status
    assert revision.valid?
  end

  test "parent is optional and self-referential" do
    step1 = revisions(:flowers_v1_step1)
    step2 = revisions(:flowers_v1_step2)
    assert_nil step1.parent
    assert_equal step1, step2.parent
  end

  test "status accepts every enum value" do
    revision = revisions(:flowers_v1_step1)
    %w[pending generating completed failed].each do |status|
      revision.status = status
      assert revision.valid?, "expected status #{status} to be valid"
    end
  end

  test "requires summary and position" do
    revision = Revision.new(
      project: projects(:flowers),
      instruction: instructions(:flowers_v1)
    )
    assert_not revision.valid?
    assert_includes revision.errors[:summary], "can't be blank"
    assert_includes revision.errors[:position], "can't be blank"
  end

  test "position is unique per instruction" do
    duplicate = Revision.new(
      project: projects(:flowers),
      instruction: instructions(:flowers_v1),
      position: revisions(:flowers_v1_step1).position,
      summary: "Duplicate position",
      prompt: "Duplicate position prompt"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "requires prompt" do
    revision = Revision.new(
      project: projects(:flowers),
      instruction: instructions(:flowers_v1),
      position: 42,
      summary: "Missing prompt"
    )
    assert_not revision.valid?
    assert_includes revision.errors[:prompt], "can't be blank"
  end
end
