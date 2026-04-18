require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "valid fixture loads" do
    assert projects(:flowers).valid?
  end

  test "requires name and workspace_path" do
    project = Project.new
    assert_not project.valid?
    assert_includes project.errors[:name], "can't be blank"
    assert_includes project.errors[:workspace_path], "can't be blank"
  end

  test "workspace_path must be unique" do
    duplicate = Project.new(name: "Other", workspace_path: projects(:flowers).workspace_path)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:workspace_path], "has already been taken"
  end

  test "has one chat and many instructions/revisions" do
    project = projects(:flowers)
    assert_equal chats(:flowers), project.chat
    assert_includes project.instructions, instructions(:flowers_v1)
    assert_equal 2, project.revisions.count
  end

  test "destroying project cascades to chat, instructions, revisions" do
    project = projects(:flowers)
    assert_difference -> { Chat.count } => -1,
                      -> { Instruction.count } => -1,
                      -> { Revision.count } => -2 do
      project.destroy!
    end
  end
end
