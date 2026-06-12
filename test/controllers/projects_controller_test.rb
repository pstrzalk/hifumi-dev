require "test_helper"

class ProjectsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    cookies[:cookie_consent] = "accepted"
    @user = create_user
    sign_in @user
  end

  test "GET /projects without auth redirects to login" do
    sign_out @user
    get projects_path
    assert_redirected_to new_user_session_path
  end

  test "GET /projects (signed in, 0 projects) renders empty-state copy" do
    get projects_path
    assert_response :success
    assert_select "p", /No projects yet/
  end

  test "GET /projects header is a 'projects' breadcrumb with the new-project cta, no section heading" do
    get projects_path
    assert_response :success
    assert_select ".eyebrow", text: "projects"
    assert_select "a.btn[href=?]", new_project_path, text: "+ New project"
    assert_select "h1.h-section", false
  end

  test "GET /projects/new header is a 'projects · new project' breadcrumb, no section heading" do
    get new_project_path
    assert_response :success
    assert_select "nav[aria-label=breadcrumb] a[href=?]", projects_path, text: /projects/i
    assert_select "nav[aria-label=breadcrumb]", text: /new project/i
    assert_select "h1.h-section", false
  end

  test "GET /projects (signed in, 2 projects) renders both names newest-first" do
    older = @user.projects.create!(name: "Older", created_at: 2.hours.ago)
    newer = @user.projects.create!(name: "Newer", created_at: 1.minute.ago)

    get projects_path
    assert_response :success
    body = @response.body
    assert_includes body, "Older"
    assert_includes body, "Newer"
    assert body.index("Newer") < body.index("Older"), "Newer should render before Older"
  end

  test "GET /projects only lists current user's projects" do
    @user.projects.create!(name: "Mine")
    Project.create!(name: "Theirs", user: users(:other))
    get projects_path
    assert_includes @response.body, "Mine"
    assert_not_includes @response.body, "Theirs"
  end

  test "GET /projects/new (signed in) renders new with placeholder text" do
    get new_project_path
    assert_response :success
    assert_select "textarea[placeholder=?]", "a yoga studio site. Class schedule, online booking, member accounts with class packs, instructor logins, an admin panel, and a calm minimal theme"
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
    assert_select "div.notice-strip--err .notice-strip__body", text: "Please describe what you want to build."
  end

  test "POST /projects with whitespace-only description is treated as blank" do
    assert_no_difference [ "Project.count" ] do
      post projects_path, params: { project: { description: "   \n\t  " } }
    end
    assert_response :unprocessable_entity
  end

  # --- per-stage model selection ----------------------------------------

  test "GET /projects/new renders one selector per stage, preselected with the owner's defaults" do
    @user.profile.update!(default_code_model: "anthropic/claude-opus-4.6")

    get new_project_path
    assert_response :success
    assert_select "select[name^='project[']", count: LLM::Stages::ALL.size
    assert_select "select#project_code_model option[selected][value=?]", "anthropic/claude-opus-4.6"
  end

  test "POST /projects persists an explicit model selection from the form" do
    post projects_path, params: { project: {
      description: "A todo list app",
      code_model: "anthropic/claude-opus-4.6"
    } }

    assert_equal "anthropic/claude-opus-4.6", Project.order(:id).last.code_model
  end

  test "POST /projects without model params falls back to the owner's profile defaults" do
    @user.profile.update!(default_chat_model: "anthropic/claude-sonnet-4.6")

    post projects_path, params: { project: { description: "A todo list app" } }

    assert_equal "anthropic/claude-sonnet-4.6", Project.order(:id).last.chat_model
  end

  test "POST /projects with a model outside the available list re-renders new with 422" do
    assert_no_difference [ "Project.count", "Chat.count" ] do
      post projects_path, params: { project: {
        description: "A todo list app",
        code_model: "openai/gpt-4o"
      } }
    end
    assert_response :unprocessable_entity
    assert_select "div.notice-strip--err .notice-strip__body", text: /is not an available model/
  end

  test "GET /projects/:id renders the model selection pane inside the build tab" do
    project = @user.projects.create!(name: "With selectors")
    project.create_chat!

    get project_path(project)
    assert_response :success
    assert_select "#pane_build turbo-frame#model_selection_pane select", count: LLM::Stages::ALL.size
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

  # --- build state on list cards ----------------------------------------

  test "GET /projects shows NEW build state for a project with no instructions" do
    @user.projects.create!(name: "Untouched")
    get projects_path
    assert_response :success
    assert_select "li.project-card.project-card--new .tag.tag--new"
  end

  test "GET /projects shows GENERATING with a blinking dot for a mid-build project" do
    project_with_build("Building", phase: :implementing)
    get projects_path
    assert_response :success
    assert_select "li.project-card.project-card--generating" do
      assert_select ".tag.tag--generating .tag-dot"
    end
  end

  test "GET /projects shows FAILED build state when the latest instruction failed" do
    project_with_build("Broken", phase: :failed)
    get projects_path
    assert_response :success
    assert_select "li.project-card.project-card--failed .tag.tag--failed"
  end

  test "GET /projects shows READY build state when the latest instruction completed" do
    project_with_build("Done", phase: :completed)
    get projects_path
    assert_response :success
    assert_select "li.project-card.project-card--ready .tag.tag--ready"
  end

  test "GET /projects eager-loads instructions in a single query regardless of project count" do
    3.times { |i| project_with_build("Build #{i}", phase: :completed) }
    assert_equal 1, instruction_query_count { get projects_path },
                 "expected one eager-loaded Instruction Load, not one per project"
  end

  private

  # A project owned by @user whose latest (only) instruction sits in `phase`.
  def project_with_build(name, phase:)
    project = @user.projects.create!(name: name)
    message = project.create_chat!.messages.create!(role: :user, content: "build it")
    project.instructions.create!(
      user_intent: "x", description: "x", phase: phase, anchor_message: message
    )
    project
  end

  # Count of "Instruction Load" queries Rails issues during the block. Filters
  # on the framework's own query label (`payload[:name]`) — DB-agnostic, no SQL
  # parsing — to pin the index's `includes(:instructions)`: one query, not N.
  def instruction_query_count
    count = 0
    callback = lambda do |*, payload|
      count += 1 if payload[:name] == "Instruction Load" && !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
