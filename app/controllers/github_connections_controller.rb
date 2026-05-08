class GithubConnectionsController < ApplicationController
  before_action :authenticate_user!

  def destroy
    current_user.github_connection&.destroy!
    redirect_to edit_user_registration_path, notice: "Disconnected from GitHub."
  end
end
