require "test_helper"

class PreviewsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestCase if false  # placeholder; ActiveJob assertions come from rails/test_help

  setup do
    cookies[:cookie_consent] = "accepted"
    @user = create_user
    sign_in @user
    @project = @user.projects.create!(name: "Preview Controller Test")
  end

  # --- create (POST /projects/:id/preview) ------------------------------

  test "POST from :stopped enqueues StartPreviewJob, flips state to :starting, returns turbo_stream" do
    @project.update!(preview_state: :stopped)

    assert_enqueued_with(job: StartPreviewJob, args: [@project.id]) do
      post project_preview_path(@project),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    @project.reload
    assert_equal "starting", @project.preview_state
    assert_match(/turbo-stream action="replace" target="preview"/, @response.body)
  end

  test "POST from :failed (retry) enqueues StartPreviewJob, flips to :starting, clears error" do
    @project.update!(preview_state: :failed, preview_error: "boom")

    assert_enqueued_with(job: StartPreviewJob, args: [@project.id]) do
      post project_preview_path(@project),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    @project.reload
    assert_equal "starting", @project.preview_state
    assert_nil @project.preview_error
  end

  test "POST from :starting returns 409 Conflict, does NOT enqueue another job" do
    @project.update!(preview_state: :starting)

    assert_no_enqueued_jobs(only: StartPreviewJob) do
      post project_preview_path(@project),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :conflict
  end

  test "POST from :running returns 409 Conflict (must Stop first)" do
    @project.update!(preview_state: :running, preview_container_id: "abc")

    assert_no_enqueued_jobs(only: StartPreviewJob) do
      post project_preview_path(@project),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :conflict
  end

  test "POST with HTML accept redirects to project" do
    @project.update!(preview_state: :stopped)
    post project_preview_path(@project)
    assert_redirected_to project_path(@project)
  end

  # --- destroy (DELETE /projects/:id/preview) ---------------------------

  test "DELETE enqueues StopPreviewJob, returns turbo_stream" do
    @project.update!(preview_state: :running, preview_container_id: "abc")

    assert_enqueued_with(job: StopPreviewJob, args: [@project.id]) do
      delete project_preview_path(@project),
             headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_match(/turbo-stream action="replace" target="preview"/, @response.body)
  end

  test "DELETE with HTML accept redirects to project" do
    delete project_preview_path(@project)
    assert_redirected_to project_path(@project)
  end

  # --- 404 --------------------------------------------------------------

  test "404 for unknown project_id" do
    post "/projects/0/preview"
    assert_response :not_found
  end

  # --- ownership --------------------------------------------------------

  test "POST without auth redirects to login" do
    sign_out @user
    @project.update!(preview_state: :stopped)
    assert_no_enqueued_jobs(only: StartPreviewJob) do
      post project_preview_path(@project)
    end
    assert_redirected_to new_user_session_path
  end

  test "POST as non-owner redirects to root with 'Not your project'" do
    sign_out @user
    sign_in users(:other)
    @project.update!(preview_state: :stopped)
    assert_no_enqueued_jobs(only: StartPreviewJob) do
      post project_preview_path(@project)
    end
    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
  end

  test "DELETE without auth redirects to login" do
    sign_out @user
    assert_no_enqueued_jobs(only: StopPreviewJob) do
      delete project_preview_path(@project)
    end
    assert_redirected_to new_user_session_path
  end

  test "DELETE as non-owner redirects to root with 'Not your project'" do
    sign_out @user
    sign_in users(:other)
    assert_no_enqueued_jobs(only: StopPreviewJob) do
      delete project_preview_path(@project)
    end
    assert_redirected_to root_path
    assert_equal "Not your project", flash[:alert]
  end
end
