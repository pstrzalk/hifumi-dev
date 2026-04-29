require "test_helper"

class PreviewsHelperTest < ActionView::TestCase
  setup do
    @project = Project.create!(name: "Helper Test", user: users(:owner))
  end

  test "stopped → previews/stopped" do
    @project.update!(preview_state: :stopped)
    assert_equal "previews/stopped", preview_pane_partial(@project)
  end

  test "starting → previews/starting" do
    @project.update!(preview_state: :starting)
    assert_equal "previews/starting", preview_pane_partial(@project)
  end

  test "running → previews/running" do
    @project.update!(preview_state: :running, preview_container_id: "abc")
    assert_equal "previews/running", preview_pane_partial(@project)
  end

  test "failed → previews/failed" do
    @project.update!(preview_state: :failed, preview_error: "x")
    assert_equal "previews/failed", preview_pane_partial(@project)
  end
end
