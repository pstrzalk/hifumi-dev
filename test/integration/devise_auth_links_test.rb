require "test_helper"

class DeviseAuthLinksTest < ActionDispatch::IntegrationTest
  test "sign-up page shows log-in prompt and no GitHub button" do
    get new_user_registration_path
    assert_response :success
    assert_match "Already have an account?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "sign-in page shows sign-up prompt, inline forgot link, and no GitHub button" do
    get new_user_session_path
    assert_response :success
    assert_match "New here?", response.body
    assert_select "a[href=?]", new_user_registration_path, text: /Create an account/
    assert_select "a[href=?]", new_user_password_path, text: "Forgot your password?"
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "forgot-password page shows log-in prompt and no GitHub button" do
    get new_user_password_path
    assert_response :success
    assert_match "Remembered your password?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end

  test "reset-password page (with valid token) shows log-in prompt and no GitHub button" do
    user = User.create!(
      email: "reset@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "R", last_name: "U",
        openrouter_api_key: "sk-or-reset-12345678901234"
      }
    )
    raw, encoded = Devise.token_generator.generate(User, :reset_password_token)
    user.update!(reset_password_token: encoded, reset_password_sent_at: Time.current)

    get edit_user_password_path(reset_password_token: raw)
    assert_response :success
    assert_match "Remembered your password?", response.body
    assert_select "a[href=?]", new_user_session_path, text: /Log in/
    assert_no_match(/Sign in with Github/i, response.body)
  end
end
