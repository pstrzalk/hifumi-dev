class ModelSelectionsController < ApplicationController
  include ProjectOwnerRequired

  def update
    if @project.update(model_selection_params)
      render_pane saved: true, status: :ok
    else
      render_pane saved: false, status: :unprocessable_entity
    end
  end

  private

  def render_pane(saved:, status:)
    render partial: "model_selections/pane",
      locals: { project: @project, saved: saved },
      status: status
  end

  def model_selection_params
    params.require(:project).permit(*LLM::Stages.project_columns)
  end
end
