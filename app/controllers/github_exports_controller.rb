class GithubExportsController < ApplicationController
  include ProjectOwnerRequired

  def create
    unless @project.exportable?
      redirect_to project_path(@project), alert: "Project not exportable yet."
      return
    end

    # First-export path supplies a `github_export` form scope (repo name +
    # private flag). The "Push latest changes" / "Retry" buttons re-POST
    # without that scope — we use existing project.github_repo_full_name
    # in the job and ignore the missing params.
    form_params = params.fetch(:github_export, {}).permit(:repo_name, :private_repo)
    name = form_params[:repo_name].presence
    private_repo = form_params[:private_repo].to_s == "1"

    @project.update!(export_state: :exporting, export_error: nil)
    ExportToGithubJob.perform_later(@project.id, repo_name: name, private_repo: private_repo)

    # Form submits inside turbo-frame "github_export_pane" — render the
    # pane partial directly. Subsequent state transitions arrive via
    # `turbo_stream_from @project` from the job's broadcast.
    render partial: "github_exports/pane", locals: { project: @project }
  end

  # Severs the link between this project and the GitHub repo it was
  # previously pushed to (clears github_repo_full_name + resets export_state).
  # The repo on github.com is NOT touched — user can keep, archive, or delete
  # it on GitHub directly. Recovery path for the divergence case: clicking
  # this returns the form so the user can export to a freshly-created repo
  # under a different name.
  def destroy
    @project.update!(
      github_repo_full_name: nil,
      export_state: :not_exported,
      export_error: nil,
      exported_at: nil
    )
    render partial: "github_exports/pane", locals: { project: @project }
  end
end
