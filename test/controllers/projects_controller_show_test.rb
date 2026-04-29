require "test_helper"

class ProjectsControllerShowTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_user
    sign_in @user
    @project = @user.projects.create!(name: "Shop")
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "flower shop")
  end

  test "renders empty active_revisions slot when no instruction exists" do
    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions", 1
    assert_select "div#active_revisions *", false
  end

  test "renders active_revisions list when an implementing instruction has revisions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :pending,
      summary: "Add Task model", prompt: "p"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions h2", "Current instruction"
    assert_select "div#active_revisions", /Add Task model/
    assert_select "div#active_revisions", /pending/
  end

  test "hides revisions for terminal-phase instructions" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :completed, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Done", prompt: "p", git_sha: "abc1234"
    )

    get project_url(@project)
    assert_response :success
    assert_select "div#active_revisions *", false
  end

  test "renders git_sha (first 7 chars) on completed revision card" do
    instruction = @project.instructions.create!(
      user_intent: "x", description: "x",
      phase: :implementing, anchor_message: @user_message
    )
    instruction.revisions.create!(
      project: @project, position: 0, status: :completed,
      summary: "Add model", prompt: "p", git_sha: "abc1234deadbeef"
    )

    get project_url(@project)
    assert_select "div#active_revisions", /abc1234\b/
  end
end
