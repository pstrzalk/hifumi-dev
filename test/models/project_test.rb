require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "valid fixture loads" do
    assert projects(:flowers).valid?
  end

  test "requires name" do
    project = Project.new
    assert_not project.valid?
    assert_includes project.errors[:name], "can't be blank"
  end

  test "workspace_path is derived from id" do
    project = projects(:flowers)
    assert_equal "storage/workspaces/#{project.id}", project.workspace_path
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
