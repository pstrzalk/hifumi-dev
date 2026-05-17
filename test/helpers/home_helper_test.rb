require "test_helper"

class HomeHelperTest < ActionView::TestCase
  test "dashboard_actions with a recent project links to it plus the full list" do
    project = Project.create!(name: "Alpha", user: users(:owner))

    html = dashboard_actions(project)

    assert_includes html, %(href="#{project_path(project)}")
    assert_includes html, "open Alpha ↗"
    assert_includes html, %(class="dash-cta")
    assert_includes html, %(href="#{projects_path}")
    assert_includes html, "all projects ↗"
    assert_includes html, %(class="dash-link")
  end

  test "dashboard_actions with no recent project shows only the start-first-project cta" do
    html = dashboard_actions(nil)

    assert_includes html, %(href="#{new_project_path}")
    assert_includes html, "start your first project ↗"
    assert_includes html, %(class="dash-cta")
    assert_not_includes html, "all projects"
    assert_not_includes html, "dash-link"
  end

  test "dashboard_actions HTML-escapes the project name" do
    project = Project.create!(name: %(<script>"x"), user: users(:owner))

    html = dashboard_actions(project)

    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>"
  end
end
