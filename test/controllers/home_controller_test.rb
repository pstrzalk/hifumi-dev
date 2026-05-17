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
    assert_select ".dash-stat__num", text: "0", count: 3
    assert_select "a", text: "+ New project"
    assert_select "a.dash-cta[href=?]", new_project_path, text: "start your first project ↗"
    assert_select "a.dash-link", count: 0
  end

  test "signed-in with projects renders correct counts and links to most-recently-active" do
    user = create_user
    sign_in user
    p1 = user.projects.create!(name: "Alpha")
    p2 = user.projects.create!(name: "Beta")
    user.projects.create!(name: "Gamma")
    p2.update!(preview_state: :running)
    p1.update!(export_state: :exported)
    p1.touch # make Alpha the most-recently-updated

    get root_path
    assert_response :success
    nums = css_select(".dash-stat__num").map(&:text)
    assert_equal %w[3 1 1], nums # projects / running / exported
    assert_select "a.dash-cta[href=?]", project_path(p1), text: "open Alpha ↗"
    assert_select "a.dash-link[href=?]", projects_path, text: "all projects ↗"
  end

  test "signed-in nav brand links to the dashboard root" do
    sign_in create_user
    get root_path
    assert_select "a.app-nav-brand[href=?]", root_path
  end
end
