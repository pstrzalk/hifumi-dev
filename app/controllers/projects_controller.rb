class ProjectsController < ApplicationController
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

    project = Project.create!(name: description.truncate(60))
    chat = GeneratorAgent.create!(project: project)
    first_message = chat.messages.create!(role: :user, content: description)
    ChatRespondJob.perform_later(first_message.id)

    redirect_to project
  end

  def show
    @project = Project.find(params[:id])
    @messages = @project.chat.messages.order(:created_at)
  end

  private

  def project_params
    params.require(:project).permit(:description)
  end
end
