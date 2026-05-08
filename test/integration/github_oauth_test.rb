require "test_helper"

class GithubOauthTest < ActionDispatch::IntegrationTest
  setup do
    @user = create_user
    sign_in @user

    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(
      provider: "github",
      uid: "583231",
      info: { nickname: "octocat", email: "octocat@example.com" },
      credentials: { token: "gho_test_access_token" }
    )
    Rails.application.env_config["devise.mapping"] = Devise.mappings[:user]
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:github]
  end

  teardown do
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:github] = nil
  end

  # --- happy path ------------------------------------------------------

  test "callback creates a github_connection and redirects with notice" do
    assert_difference -> { GithubConnection.count }, 1 do
      get user_github_omniauth_callback_path
    end

    assert_redirected_to edit_user_registration_path
    follow_redirect!
    assert_match(/Connected as @octocat/, flash[:notice].to_s)

    conn = @user.reload.github_connection
    assert_equal "github_oauth",         conn.provider
    assert_equal "octocat",              conn.github_username
    assert_equal 583231,                 conn.github_user_id
    assert_equal "gho_test_access_token", conn.access_token
  end

  # --- failure path ----------------------------------------------------

  test "callback failure redirects with alert and creates no row" do
    OmniAuth.config.mock_auth[:github] = :invalid_credentials

    assert_no_difference -> { GithubConnection.count } do
      get user_github_omniauth_callback_path
      follow_redirect! while response.redirect? && @user.reload.github_connection.nil? && response.location !~ /registration/
    end

    # Devise routes failure → /users/auth/failure → registration edit with alert.
    follow_redirect! while response.redirect?
    assert_match(/GitHub connection failed/i, flash[:alert].to_s)
  end

  # --- reconnect updates the existing row ------------------------------

  test "callback reuses the existing row instead of creating a duplicate" do
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "old-handle",
      github_user_id: 1,
      access_token: "gho_old"
    )

    assert_no_difference -> { GithubConnection.count } do
      get user_github_omniauth_callback_path
    end

    conn = @user.reload.github_connection
    assert_equal "octocat",              conn.github_username
    assert_equal 583231,                 conn.github_user_id
    assert_equal "gho_test_access_token", conn.access_token
  end

  # --- disconnect ------------------------------------------------------

  test "DELETE /github_connection destroys the row and redirects with notice" do
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )

    assert_difference -> { GithubConnection.count }, -1 do
      delete github_connection_path
    end

    assert_redirected_to edit_user_registration_path
    follow_redirect!
    assert_match(/Disconnected from GitHub/, flash[:notice].to_s)
  end

  test "DELETE /github_connection without an existing row redirects without error" do
    assert_no_difference -> { GithubConnection.count } do
      delete github_connection_path
    end
    assert_redirected_to edit_user_registration_path
  end

  # --- profile UI shows correct state ----------------------------------

  test "profile page shows Connect button when no connection" do
    get edit_user_registration_path
    assert_response :success
    assert_match "Connect GitHub", response.body
  end

  test "profile page shows username + Disconnect when connected" do
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_x"
    )

    get edit_user_registration_path
    assert_response :success
    assert_match "@octocat",          response.body
    assert_match "Disconnect GitHub", response.body
  end
end
