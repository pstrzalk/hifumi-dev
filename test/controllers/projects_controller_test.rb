require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "GET / renders new with placeholder text" do
    get root_path
    assert_response :success
    assert_select "textarea[placeholder=?]", "a flower shop page, with full payment system"
  end

  test "GET / renders the three suggestion buttons with their labels" do
    get root_path
    assert_response :success
    [ "Flower shop with checkout", "Todo list with Tailwind", "Team standup tracker" ].each do |label|
      assert_select "button", text: label
    end
  end

  test "POST /projects with valid description creates project, chat, system + user messages, then redirects" do
    assert_difference -> { Project.count } => 1,
                      -> { Chat.count } => 1,
                      -> { Message.count } => 2 do
      post projects_path, params: { project: { description: "A todo list app" } }
    end

    project = Project.order(:id).last
    assert_redirected_to project_path(project)
    user_message = project.chat.messages.find_by!(role: :user)
    assert_equal "A todo list app", user_message.content
    assert_equal 1, project.chat.messages.where(role: :system).count
  end

  test "POST /projects sets name to description truncated to 60 chars and derives workspace_path from id" do
    long_description = "A" * 200
    post projects_path, params: { project: { description: long_description } }
    project = Project.order(:id).last
    assert_equal long_description.truncate(60), project.name
    assert_equal "storage/workspaces/project_#{project.id}", project.workspace_path
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

  test "GET /projects/:id with no messages renders 200 and empty messages container" do
    project = Project.create!(name: "Empty")
    project.create_chat!
    get project_path(project)
    assert_response :success
    assert_select "#messages", count: 1
    assert_select "#messages > *", count: 0
  end

  test "GET /projects/:id with fixture messages renders each via _message partial" do
    project = projects(:flowers)
    get project_path(project)
    assert_response :success
    project.chat.messages.each do |message|
      assert_select "##{ActionView::RecordIdentifier.dom_id(message)}"
    end
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
end
