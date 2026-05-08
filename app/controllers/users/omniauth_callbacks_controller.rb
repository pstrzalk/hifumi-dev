class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  before_action :authenticate_user!

  def github
    auth = request.env["omniauth.auth"]
    connection = current_user.github_connection || current_user.build_github_connection

    connection.update!(
      provider:        "github_oauth",
      github_username: auth.info.nickname,
      github_user_id:  auth.uid.to_i,
      access_token:    auth.credentials.token
      # refresh_token / expires_at intentionally not set — OAuth App tokens don't expire.
    )

    redirect_to edit_user_registration_path, notice: "Connected as @#{connection.github_username}."
  end

  def failure
    redirect_to edit_user_registration_path, alert: "GitHub connection failed: #{failure_message}"
  end
end
