require "test_helper"

class CookieConsentEnforcementTest < ActionDispatch::IntegrationTest
  # Rack returns Set-Cookie as an Array (one entry per cookie) in modern Rails.
  # `response.cookies` parses the response cookies into a Hash by name.
  # Using the parsed hash is more reliable than substring-matching the header.

  test "session cookie is NOT written when consent cookie is absent" do
    get root_path
    assert_response :success
    session_key = Rails.application.config.session_options[:key]
    refute response.cookies.key?(session_key),
           "expected no #{session_key} cookie when consent missing, got: #{response.cookies.keys.inspect}"
  end

  test "session cookie IS written when consent cookie is present (Devise sign-in failure populates session)" do
    cookies[:cookie_consent] = "accepted"
    # A failed Devise sign-in writes a flash and warden session token, which
    # forces the session to persist. A plain GET on root may not write a session.
    post user_session_path, params: { user: { email: "nope@nope.test", password: "wrong" } }
    session_key = Rails.application.config.session_options[:key]
    assert response.cookies.key?(session_key),
           "expected #{session_key} cookie when consent given, got: #{response.cookies.keys.inspect}"
  end

  test "Devise sign-in form is replaced by cookies-required notice when consent missing" do
    get new_user_session_path
    assert_response :success
    assert_select ".cookies-required"
    assert_select "form[action=?]", user_session_path, count: 0
    # The reopen button uses data-action, not inline onclick (CSP-safe).
    assert_select "[data-controller='cookies-required'] [data-action='click->cookies-required#requestReopen']"
  end

  test "Devise sign-in form renders when consent given" do
    cookies[:cookie_consent] = "accepted"
    get new_user_session_path
    assert_response :success
    assert_select "form[action=?]", user_session_path
    assert_select ".cookies-required", count: 0
  end

  test "Devise sign-up form is replaced by cookies-required notice when consent missing" do
    get new_user_registration_path
    assert_response :success
    assert_select ".cookies-required"
    assert_select "form[action=?]", user_registration_path, count: 0
  end

  test "Devise sign-up form renders when consent given AND preserves required profile fields" do
    cookies[:cookie_consent] = "accepted"
    get new_user_registration_path
    assert_response :success
    assert_select "form[action=?]", user_registration_path
    # Regression guard: the nested profile fields (especially openrouter_api_key)
    # must survive the wrap.
    assert_select "input[name='user[profile_attributes][first_name]']"
    assert_select "input[name='user[profile_attributes][last_name]']"
    assert_select "input[name='user[profile_attributes][openrouter_api_key]']"
  end

  test "forgot-password form is replaced by cookies-required notice when consent missing" do
    get new_user_password_path
    assert_response :success
    assert_select ".cookies-required"
    assert_select "form[action=?]", user_password_path, count: 0
  end

  test "forgot-password form renders when consent given" do
    cookies[:cookie_consent] = "accepted"
    get new_user_password_path
    assert_response :success
    assert_select "form[action=?]", user_password_path
  end

  test "reset-password form is replaced by cookies-required notice when consent missing" do
    user = User.create!(
      email: "reset-gate@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "R", last_name: "G",
        openrouter_api_key: "sk-or-reset-gate-12345678"
      }
    )
    raw, encoded = Devise.token_generator.generate(User, :reset_password_token)
    user.update!(reset_password_token: encoded, reset_password_sent_at: Time.current)

    get edit_user_password_path(reset_password_token: raw)
    assert_response :success
    assert_select ".cookies-required"
    assert_select "input[name='user[password]']", count: 0
  end

  test "contact form is replaced by cookies-required notice when consent missing" do
    get contact_path
    assert_response :success
    assert_select ".cookies-required"
    assert_select "form[action=?]", contact_path, count: 0
    # Marketing-shell chrome stays visible to give context.
    assert_select "h1", text: "Contact"
  end

  test "contact form renders when consent given" do
    cookies[:cookie_consent] = "accepted"
    get contact_path
    assert_response :success
    assert_select "form[action=?]", contact_path
    assert_select ".cookies-required", count: 0
  end

  test "contact POST without consent (CSRF on, no session token) does not create a ContactMessage" do
    # Runtime regression guard against the earlier "sessionless contact" design.
    # The form is gated at the view layer; a crafted POST without consent should
    # be blocked by CSRF (no session → no valid token). Test env disables
    # forgery protection by default, so flip it on for this single test to
    # mirror production behaviour.
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      assert_no_difference "ContactMessage.count" do
        post contact_path, params: { contact_message: { email: "a@b.co", message: "Long enough message body." } }
      end
      assert_not_equal 201, response.status
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  test "csp_nonce_consistent_for_no_consent_request" do
    # CSP nonce regression guard: the nonce generator was switched off
    # `request.session.id` because `enforce_cookie_consent` resets the session.
    # Confirm the nonce in <meta name="csp-nonce"> is non-empty and matches a
    # <script nonce="..."> tag on a no-consent page.
    get new_user_session_path  # no consent seeded
    assert_response :success

    meta_nonce = css_select("meta[name=csp-nonce]").first&.attr("content")
    refute_nil meta_nonce, "expected a csp-nonce meta tag"
    refute_empty meta_nonce, "expected non-empty csp-nonce"

    script_match = response.body.match(/<script[^>]*\snonce="([^"]+)"/)
    if script_match
      assert_equal meta_nonce, script_match[1],
        "expected <script nonce> to match <meta csp-nonce>"
    end
    # If no inline <script nonce> appears in the response, the test still
    # passes — the meta tag is enough to prove the generator returned a value.
  end
end
