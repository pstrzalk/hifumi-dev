require "test_helper"

class GithubExportFlowTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
    @owner = create_user
    @project = @owner.projects.create!(name: "Exportable Project")
    @chat = @project.create_chat!
    msg = @chat.messages.create!(role: :user, content: "do the thing")
    # exportable? requires at least one completed instruction.
    @project.instructions.create!(
      anchor_message: msg,
      description: "did the thing",
      user_intent: "thing",
      phase: :completed
    )
    @owner.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_test"
    )

    sign_in @owner
  end

  # --- visibility -------------------------------------------------------

  test "owner sees Export form when connected and has a completed instruction" do
    get project_path(@project)
    assert_response :success
    assert_match "Export to GitHub", response.body
    assert_match "Repository name",  response.body
  end

  test "owner without github_connection sees the Connect-on-profile prompt instead of the form" do
    @owner.github_connection.destroy!
    get project_path(@project)
    assert_response :success
    assert_match "Connect GitHub on", response.body
    refute_match "Repository name",   response.body
  end

  test "owner with connection but no completed instruction sees 'complete first build' prompt" do
    @project.instructions.destroy_all
    get project_path(@project)
    assert_response :success
    assert_match "Complete the first build", response.body
    refute_match "Repository name",           response.body
  end

  # --- non-owner --------------------------------------------------------

  test "non-owner POST is redirected with alert (ProjectOwnerRequired)" do
    other = create_user
    sign_in other
    post project_github_export_path(@project), params: { github_export: { repo_name: "x", private_repo: "1" } }
    assert_redirected_to root_path
    assert_match(/Not your project/i, flash[:alert].to_s)
  end

  # --- create flow ------------------------------------------------------

  test "POST with form params enqueues job and flips state to :exporting" do
    assert_enqueued_with(
      job: ExportToGithubJob,
      args: [@project.id, { repo_name: "my-repo", private_repo: true }]
    ) do
      post project_github_export_path(@project),
           params: { github_export: { repo_name: "my-repo", private_repo: "1" } }
    end

    assert_response :success
    assert_equal "exporting", @project.reload.export_state
  end

  test "POST without :github_export scope (Push latest changes / Retry path) does not raise" do
    @project.update!(github_repo_full_name: "octocat/exportable-project", export_state: :exported)

    assert_enqueued_with(
      job: ExportToGithubJob,
      args: [@project.id, { repo_name: nil, private_repo: false }]
    ) do
      post project_github_export_path(@project)
    end

    assert_response :success
    assert_equal "exporting", @project.reload.export_state
  end

  test "POST when project not exportable redirects with alert" do
    @owner.github_connection.destroy!
    assert_no_enqueued_jobs do
      post project_github_export_path(@project),
           params: { github_export: { repo_name: "x", private_repo: "1" } }
    end
    assert_redirected_to project_path(@project)
    assert_match(/not exportable/i, flash[:alert].to_s)
  end

  test "after disconnect on an already-exported project: Push button hidden, Reconnect hint shown" do
    @project.update!(github_repo_full_name: "octocat/exportable-project", export_state: :exported)
    @owner.github_connection.destroy!

    get project_path(@project)
    assert_response :success
    refute_match "Push latest changes", response.body
    assert_match "Reconnect GitHub",    response.body
  end

  test "after disconnect on a failed export: Retry button hidden, Reconnect hint shown" do
    @project.update!(export_state: :failed, export_error: "GitHub token was revoked.")
    @owner.github_connection.destroy!

    get project_path(@project)
    assert_response :success
    # The Retry button form posts to the export path; assert no submit input labelled "Retry".
    refute_match ">Retry<",          response.body
    assert_match "Reconnect GitHub", response.body
  end

  test "DELETE clears the export link, returns the form (no GitHub-side delete)" do
    @project.update!(
      github_repo_full_name: "octocat/exportable-project",
      export_state: :failed,
      export_error: "divergence"
    )

    delete project_github_export_path(@project)

    assert_response :success
    @project.reload
    assert_nil @project.github_repo_full_name
    assert_equal "not_exported", @project.export_state
    assert_nil @project.export_error
    # The form is rendered (project is exportable: connected + completed instruction).
    assert_match "Repository name", response.body
  end

  test "DELETE by non-owner is forbidden" do
    @project.update!(github_repo_full_name: "octocat/x", export_state: :failed)
    other = create_user
    sign_in other

    delete project_github_export_path(@project)
    assert_redirected_to root_path
    assert_equal "octocat/x", @project.reload.github_repo_full_name
  end

  test "failed pane shows 'Create a new repository' button when there's an existing repo link" do
    @project.update!(
      github_repo_full_name: "octocat/exportable-project",
      export_state: :failed,
      export_error: "divergence"
    )

    get project_path(@project)
    assert_response :success
    assert_match "Create a new repository", response.body
  end

  test "POST response renders the exporting pane (turbo-frame) so the form swaps in place" do
    post project_github_export_path(@project),
         params: { github_export: { repo_name: "my-repo", private_repo: "1" } }
    assert_response :success
    assert_match 'id="github_export_pane"', response.body
    assert_match "Exporting to GitHub",    response.body
  end
end
