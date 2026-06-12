class PreviewsController < ApplicationController
  include ProjectOwnerRequired

  def create
    # Guard: only allow start from terminal states. Prevents double-click /
    # stale-tab races that would result in `docker run --name preview-N` losing
    # to "name already in use" on the second attempt.
    unless @project.preview_state.in?(%w[stopped failed])
      return head :conflict
    end

    @project.update!(preview_state: :starting, preview_error: nil)
    StartPreviewJob.perform_later(@project.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "preview", partial: "previews/pane", locals: { project: @project }
        )
      end
      format.html { redirect_to @project }
    end
  end

  def destroy
    StopPreviewJob.perform_later(@project.id)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "preview", partial: "previews/pane", locals: { project: @project }
        )
      end
      format.html { redirect_to @project }
    end
  end
end
