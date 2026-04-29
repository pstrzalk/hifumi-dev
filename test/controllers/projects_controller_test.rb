require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = create_user
    sign_in @user
  end

  test "GET /projects/new (signed in) renders new with placeholder text" do
    get new_project_path
    assert_response :success
    assert_select "textarea[placeholder=?]", "a flower shop page, with full payment system"
  end

  test "GET /projects/new (signed in) renders the three suggestion buttons with their labels" do
    get new_project_path
    assert_response :success
    [ "Flower shop with checkout", "Todo list with Tailwind", "Team standup tracker" ].each do |label|
      assert_select "button", text: label
    end
  end

  test "GET /projects/new without auth redirects to login" do
    sign_out @user
    get new_project_path
    assert_redirected_to new_user_session_path
  end

  test "POST /projects with valid description creates project, chat, system + user messages, then redirects" do
    assert_difference -> { Project.count } => 1,
                      -> { Chat.count } => 1,
                      -> { Message.count } => 2 do
      post projects_path, params: { project: { description: "A todo list app" } }
    end

    project = Project.order(:id).last
    assert_equal @user.id, project.user_id
    assert_redirected_to project_path(project)
    user_message = project.chat.messages.find_by!(role: :user)
    assert_equal "A todo list app", user_message.content
    assert_equal 1, project.chat.messages.where(role: :system).count
  end

  test "POST /projects without auth redirects to login" do
    sign_out @user
    assert_no_difference [ "Project.count" ] do
      post projects_path, params: { project: { description: "A todo list app" } }
    end
    assert_redirected_to new_user_session_path
  end

  test "POST /projects sets name to description truncated to 60 chars and derives workspace_path from id" do
    long_description = "A" * 200
    post projects_path, params: { project: { description: long_description } }
    project = Project.order(:id).last
    assert_equal long_description.truncate(60), project.name
    assert_equal File.join(Project.workspace_root, "project_#{project.id}"), project.workspace_path
  end

  test "POST /projects twice produces distinct workspace_path values" do
    post projects_path, params: { project: { description: "First app" } }
    first = Project.order(:id).last
    post projects_path, params: { project: { description: "Second app" } }
    second = Project.order(:id).last
    assert_not_equal first.id, second.id
    assert_not_equal first.workspace_path, second.workspace_path
  end

  test "POST /projects with blank description does not persist and re-renders new with 422" do
    assert_no_difference [ "Project.count", "Chat.count", "Message.count" ] do
      post projects_path, params: { project: { description: "" } }
    end
    assert_response :unprocessable_entity
    assert_select "div.text-red-700", text: "Please describe what you want to build."
  end

  test "POST /projects with whitespace-only description is treated as blank" do
    assert_no_difference [ "Project.count" ] do
      post projects_path, params: { project: { description: "   \n\t  " } }
    end
    assert_response :unprocessable_entity
  end

  test "GET /projects/:id (owner) with no messages renders 200 and empty messages container" do
    project = @user.projects.create!(name: "Empty")
    project.create_chat!
    get project_path(project)
    assert_response :success
    assert_select "#messages", count: 1
    assert_select "#messages > *", count: 0
  end

  test "GET /projects/:id (owner) with fixture messages renders each via _message partial" do
    project = projects(:flowers)
    sign_in users(:owner)
    get project_path(project)
    assert_response :success
    project.chat.messages.each do |message|
      assert_select "##{ActionView::RecordIdentifier.dom_id(message)}"
    end
  end

  test "GET /projects/:id (non-owner) redirects with 'Not your project'" do
    project = projects(:flowers)
    other = users(:other) # signed in via setup, but we want @user to NOT own this
    sign_out @user
    sign_in other
    get project_path(project)
    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
  end

  test "GET /projects/:id without auth redirects to login" do
    project = projects(:flowers)
    sign_out @user
    get project_path(project)
    assert_redirected_to new_user_session_path
  end

  test "GET /projects/:id with unknown id returns 404" do
    get project_path(id: 999999)
    assert_response :not_found
  end

  test "POST /projects (valid) enqueues ChatRespondJob with the first user message id" do
    assert_enqueued_with(job: ChatRespondJob) do
      post projects_path, params: { project: { description: "Build a thing" } }
    end
    first_message = Project.order(:id).last.chat.messages.where(role: :user).order(:created_at).first
    assert_enqueued_with(job: ChatRespondJob, args: [ first_message.id ])
  end

  test "POST /projects (blank) does NOT enqueue ChatRespondJob" do
    assert_no_enqueued_jobs(only: ChatRespondJob) do
      post projects_path, params: { project: { description: "" } }
    end
  end

  test "DELETE /projects/:id (owner) destroys the project" do
    project = @user.projects.create!(name: "To be deleted")
    assert_difference -> { Project.count } => -1 do
      delete project_path(project)
    end
    assert_redirected_to projects_path
  end

  test "DELETE /projects/:id (non-owner) does NOT destroy" do
    project = projects(:flowers)
    sign_out @user
    sign_in users(:other)
    assert_no_difference [ "Project.count" ] do
      delete project_path(project)
    end
    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
  end
end
