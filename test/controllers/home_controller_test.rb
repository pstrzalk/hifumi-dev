require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
  end

  test "anon at / renders unchanged marketing, not the dashboard" do
    get root_path
    assert_response :success
    assert_select "a", text: "Sign up"
    assert_select "a", text: "Log in"
    assert_no_match(/Welcome back/, @response.body)
  end

  test "signed-in with 0 projects renders dashboard, zero stats, start-first-project cta, no all-projects link" do
    sign_in create_user
    get root_path
    assert_response :success
    assert_select "h1.h-section", text: "Welcome back, Test"
    assert_select ".page-head .eyebrow", text: "home"
    assert_select ".dash-stat__num", text: "0", count: 5
    assert_equal %w[projects new generating failed ready],
                 css_select(".dash-stat__label").map(&:text)
    assert_select "a", text: "+ New project"
    assert_select "a.dash-cta[href=?]", new_project_path, text: "start your first project ↗"
    assert_select "a.dash-link", count: 0
  end

  test "signed-in with projects renders a build-state breakdown summing to the projects total" do
    user = create_user
    sign_in user
    user.projects.create!(name: "New A")
    user.projects.create!(name: "New B")
    project_with_build(user, name: "Generating", phase: :implementing)
    project_with_build(user, name: "Failed", phase: :failed)
    ready = project_with_build(user, name: "Ready", phase: :completed)
    ready.touch # make Ready the most-recently-active (survives Phase 5's touch chain)

    get root_path
    assert_response :success
    nums = css_select(".dash-stat__num").map(&:text)
    assert_equal %w[5 2 1 1 1], nums # projects / new / generating / failed / ready
    assert_equal nums.first.to_i, nums.drop(1).sum(&:to_i),
                 "the four build-state counts must partition the projects total"
    assert_select "a.dash-cta[href=?]", project_path(ready), text: "open Ready ↗"
    assert_select "a.dash-link[href=?]", projects_path, text: "all projects ↗"
  end

  test "dashboard eager-loads instructions in a single query regardless of project count" do
    user = create_user
    sign_in user
    3.times { |i| project_with_build(user, name: "Build #{i}", phase: :completed) }

    assert_equal 1, instruction_query_count { get root_path },
                 "expected one eager-loaded Instruction Load, not one per project"
  end

  test "signed-in nav brand links to the dashboard root" do
    sign_in create_user
    get root_path
    assert_select "a.app-nav-brand[href=?]", root_path
  end

  private

  # A project whose latest (only) instruction sits in `phase`, so its
  # derived build_state is generating / failed / ready.
  def project_with_build(user, name:, phase:)
    project = user.projects.create!(name: name)
    message = project.create_chat!.messages.create!(role: :user, content: "build it")
    project.instructions.create!(
      user_intent: "x", description: "x", phase: phase, anchor_message: message
    )
    project
  end

  # Count of "Instruction Load" queries Rails issues during the block. Filters
  # on the framework's own query label (`payload[:name]`) — DB-agnostic, no SQL
  # parsing — to pin the dashboard's `includes(:instructions)`: one query, not N.
  def instruction_query_count
    count = 0
    callback = lambda do |*, payload|
      count += 1 if payload[:name] == "Instruction Load" && !payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
