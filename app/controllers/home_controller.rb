class HomeController < ApplicationController
  def index
    return unless user_signed_in?

    load_dashboard
    render :dashboard
  end

  private

  def load_dashboard
    projects        = current_user.projects.includes(:instructions).to_a
    counts          = projects.group_by(&:build_state).transform_values(&:size)
    @first_name     = current_user.profile.first_name
    @projects_count = projects.size
    @state_counts   = %i[new generating failed ready].index_with { |s| counts[s] || 0 }
    @recent_project = projects.max_by(&:updated_at)
  end
end
