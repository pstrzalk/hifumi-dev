class ProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_project_and_authorize!, only: [ :show, :destroy ]

  def index
    @projects = current_user.projects.includes(:instructions).order(created_at: :desc)
  end

  def new
    @project = build_project
  end

  def create
    description = project_params[:description].to_s.strip

    if description.blank?
      @project = build_project
      @error = "Please describe what you want to build."
      return render :new, status: :unprocessable_entity
    end

    @project = build_project(name: description.truncate(60))
    unless @project.save
      @error = @project.errors.full_messages.to_sentence
      return render :new, status: :unprocessable_entity
    end

    chat = GeneratorAgent.create!(project: @project)
    first_message = chat.messages.create!(role: :user, content: description)
    # Delay so the redirected-to /projects/:id page can mount its Turbo Cable
    # subscription before the assistant placeholder broadcasts; otherwise the
    # browser misses the append and the later `replace message_<id>` no-ops.
    # See docs/09-ideas/05-followups.md (2026-05-15: chat-on-new-project race).
    ChatRespondJob.set(wait: 0.5.seconds).perform_later(first_message.id)

    redirect_to @project
  end

  def show
    @chat_events = build_chat_events(@project)
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

  def build_chat_events(project)
    messages = project.chat.messages.includes(:tool_calls).to_a
    status_instructions = project.instructions
      .where(phase: %w[completed failed])
      .to_a
    (messages + status_instructions).sort_by { |e| event_timestamp(e) }
  end

  def event_timestamp(event)
    case event
    when Message     then event.created_at
    when Instruction then event.updated_at
    end
  end

  # New projects start from the owner's per-stage model defaults; an explicit
  # selection posted from the new-project form wins over them.
  def build_project(attrs = {})
    current_user.projects.new(
      current_user.profile.default_models_for_project
        .merge(posted_model_selection)
        .merge(attrs)
    )
  end

  def posted_model_selection
    return {} if params[:project].blank?
    project_params.slice(*LLM::Stages.project_columns).to_h.symbolize_keys
  end

  def project_params
    params.require(:project).permit(:description, *LLM::Stages.project_columns)
  end
end
