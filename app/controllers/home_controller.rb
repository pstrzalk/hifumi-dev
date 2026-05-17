class HomeController < ApplicationController
  def index
    return unless user_signed_in?

    load_dashboard
    render :dashboard
  end

  private

  def load_dashboard
    projects        = current_user.projects
    @first_name     = current_user.profile.first_name
    @member_since   = current_user.created_at
    @projects_count = projects.count
    @running_count  = projects.where(preview_state: :running).count
    @exported_count = projects.where(export_state: :exported).count
    @recent_project = projects.order(updated_at: :desc).first
  end
end
