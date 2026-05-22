require "test_helper"

class Users::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    cookies[:cookie_consent] = "accepted"
  end

  test "GET /users/sign_up renders form with nested profile fields" do
    get new_user_registration_path
    assert_response :success
    assert_select "input[name='user[email]']"
    assert_select "input[name='user[password]']"
    assert_select "input[name='user[profile_attributes][first_name]']"
    assert_select "input[name='user[profile_attributes][last_name]']"
    assert_select "input[name='user[profile_attributes][openrouter_api_key]']"
  end

  test "POST /users (sign up) with all five fields creates user + profile" do
    assert_difference -> { User.count } => 1, -> { Profile.count } => 1 do
      post user_registration_path, params: {
        user: {
          email: "signup@example.com",
          password: "password123",
          password_confirmation: "password123",
          profile_attributes: {
            first_name: "Pat",
            last_name: "Smith",
            openrouter_api_key: "sk-or-signup-1234567890ab"
          }
        }
      }
    end

    user = User.find_by!(email: "signup@example.com")
    assert_equal "Pat", user.profile.first_name
    assert_equal "Smith", user.profile.last_name
    assert_equal "sk-or-signup-1234567890ab", user.profile.openrouter_api_key
  end

  test "POST /users with blank openrouter_api_key fails validation" do
    assert_no_difference -> { User.count } do
      post user_registration_path, params: {
        user: {
          email: "blankkey@example.com",
          password: "password123",
          password_confirmation: "password123",
          profile_attributes: {
            first_name: "Pat",
            last_name: "Smith",
            openrouter_api_key: ""
          }
        }
      }
    end
    assert_response :unprocessable_entity
  end

  test "POST /users/sign_in establishes a session for valid credentials" do
    User.create!(
      email: "signin@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "X", last_name: "Y",
        openrouter_api_key: "sk-or-signin-987654321"
      }
    )

    post user_session_path, params: {
      user: { email: "signin@example.com", password: "password123" }
    }
    assert_redirected_to root_path
    follow_redirect! # root_path now renders the dashboard for signed-in users
    assert_response :success
  end

  test "PUT /users (update) profile-only without current_password succeeds (rotates key, updates name)" do
    user = User.create!(
      email: "rotate@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "Pat", last_name: "Smith",
        openrouter_api_key: "sk-or-existing-key-abc12345"
      }
    )
    sign_in user

    put user_registration_path, params: {
      user: {
        profile_attributes: {
          id: user.profile.id,
          first_name: "Patricia",
          last_name: "Smith",
          openrouter_api_key: ""
        }
      }
    }

    user.profile.reload
    assert_equal "Patricia", user.profile.first_name
    assert_equal "sk-or-existing-key-abc12345", user.profile.openrouter_api_key
  end

  test "PUT /users (update) with new key (no current_password) rotates the key" do
    user = User.create!(
      email: "rotate2@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "Pat", last_name: "Smith",
        openrouter_api_key: "sk-or-old-key-xxxxxxxxx"
      }
    )
    sign_in user

    put user_registration_path, params: {
      user: {
        profile_attributes: {
          id: user.profile.id,
          first_name: "Pat",
          last_name: "Smith",
          openrouter_api_key: "sk-or-rotated-newkeyzzzz"
        }
      }
    }

    user.profile.reload
    assert_equal "sk-or-rotated-newkeyzzzz", user.profile.openrouter_api_key
  end

  test "PUT /users password change without current_password is rejected" do
    user = User.create!(
      email: "pwchange@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "Pat", last_name: "Smith",
        openrouter_api_key: "sk-or-pwchange-key-12345678"
      }
    )
    sign_in user
    old_encrypted = user.encrypted_password

    put user_registration_path, params: {
      user: {
        password: "newpassword456",
        password_confirmation: "newpassword456",
        profile_attributes: { id: user.profile.id, first_name: "Pat", last_name: "Smith" }
      }
    }
    assert_response :unprocessable_entity
    assert_equal old_encrypted, user.reload.encrypted_password
  end

  test "PUT /users password change with valid current_password succeeds" do
    user = User.create!(
      email: "pwok@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "Pat", last_name: "Smith",
        openrouter_api_key: "sk-or-pwok-key-1234567890"
      }
    )
    sign_in user
    old_encrypted = user.encrypted_password

    put user_registration_path, params: {
      user: {
        current_password: "password123",
        password: "newpassword456",
        password_confirmation: "newpassword456",
        profile_attributes: { id: user.profile.id, first_name: "Pat", last_name: "Smith" }
      }
    }
    assert_not_equal old_encrypted, user.reload.encrypted_password
  end

  test "GET /users/edit renders the account breadcrumb and three hi-fu-mi tabs" do
    user = User.create!(
      email: "tabs@example.com", password: "password123",
      profile_attributes: { first_name: "Pat", last_name: "Smith",
                            openrouter_api_key: "sk-or-tabs-123456789" }
    )
    sign_in user

    get edit_user_registration_path
    assert_response :success

    assert_select ".page-head .eyebrow", text: "account"
    assert_select "h1.h-section", false
    assert_select "nav.tab-nav[role=tablist]"
    assert_select "button[role=tab]", count: 3
    assert_select "#tab_profile[aria-selected=true]"
    assert_select "#tab_integrations[aria-selected=false]"
    assert_select "#tab_danger[aria-selected=false]"
    assert_select "#tab_profile .tab-button__numeral", text: "一"
    assert_select "#tab_integrations .tab-button__numeral", text: "二"
    assert_select "#tab_danger .tab-button__numeral", text: "三"
    assert_select "#pane_profile[role=tabpanel]"
    assert_select "#pane_integrations[role=tabpanel]"
    assert_select "#pane_danger[role=tabpanel]"
  end

  test "GET /users/edit puts OpenRouter key in its own form inside Integrations, not the profile form" do
    user = User.create!(
      email: "split@example.com", password: "password123",
      profile_attributes: { first_name: "Pat", last_name: "Smith",
                            openrouter_api_key: "sk-or-split-123456789" }
    )
    sign_in user

    get edit_user_registration_path
    assert_response :success

    assert_select "#pane_profile input[name='user[email]']"
    assert_select "#pane_profile input[name='user[profile_attributes][first_name]']"
    assert_select "#pane_profile input[name='user[profile_attributes][openrouter_api_key]']", count: 0

    assert_select "#pane_integrations input[name='user[profile_attributes][openrouter_api_key]']"
    assert_select "#pane_integrations form#openrouter_key_form"

    # The OpenRouter form's namespace: "or" must de-duplicate the hidden
    # profile-id input that BOTH fields_for :profile blocks auto-emit.
    assert_select "#pane_profile input#user_profile_attributes_id", count: 1
    assert_select "#pane_integrations input#or_user_profile_attributes_id", count: 1
    assert_select "#pane_integrations input#user_profile_attributes_id", count: 0
    assert_select "#pane_integrations input#or_user_profile_attributes_openrouter_api_key"

    assert_select "#pane_danger form[action=?]", user_registration_path
  end
end
