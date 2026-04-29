class ProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_project_and_authorize!, only: [:show, :destroy]

  def new
    @project = Project.new
  end

  def create
    description = project_params[:description].to_s.strip

    if description.blank?
      @project = Project.new
      @error = "Please describe what you want to build."
      return render :new, status: :unprocessable_entity
    end

    project = current_user.projects.create!(name: description.truncate(60))
    chat = GeneratorAgent.create!(project: project)
    first_message = chat.messages.create!(role: :user, content: description)
    ChatRespondJob.perform_later(first_message.id)

    redirect_to project
  end

  def show
    @messages = @project.chat.messages.order(:created_at)
    @active_revisions = active_revisions_for(@project)
  end

  def destroy
    @project.destroy!
    redirect_to projects_path, notice: "Project deleted"
  end

  private

  def load_project_and_authorize!
    @project = Project.find(params[:id])
    unless @project.user_id == current_user.id
      redirect_to root_path, alert: "Not your project"
    end
  end

  def active_revisions_for(project)
    instruction = project.instructions
      .where.not(phase: %w[completed failed cancelled])
      .order(:created_at).last
    instruction&.revisions&.order(:position) || []
  end

  def project_params
    params.require(:project).permit(:description)
  end
end
