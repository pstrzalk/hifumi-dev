module ProjectOwnerRequired
  extend ActiveSupport::Concern

  included do
    before_action :authenticate_user!
    before_action :load_project_and_authorize!
  end

  private

  def load_project_and_authorize!
    @project = Project.find(params[:project_id] || params[:id])
    redirect_to root_path, alert: "Not your project" unless @project.user_id == current_user&.id
  end
end
