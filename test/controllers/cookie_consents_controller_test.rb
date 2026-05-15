require "test_helper"

class CookieConsentsControllerTest < ActionDispatch::IntegrationTest
  test "POST /cookie_consent sets the cookie and redirects to referer" do
    post cookie_consent_path, headers: { "HTTP_REFERER" => root_url }
    assert_redirected_to root_url
    assert_equal "accepted", cookies[:cookie_consent]
  end

  test "POST /cookie_consent without a referer redirects to root" do
    post cookie_consent_path
    assert_redirected_to root_path
  end

  test "POST /cookie_consent rejects off-host referer" do
    post cookie_consent_path, headers: { "HTTP_REFERER" => "https://evil.example/foo" }
    assert_redirected_to root_path
  end

  test "POST /cookie_consent works with CSRF protection enabled (no session, no token)" do
    # Runtime check: temporarily flip `allow_forgery_protection` on, post
    # without a valid token, and assert the controller still succeeds —
    # proving the `skip_before_action :verify_authenticity_token` is wired.
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    begin
      post cookie_consent_path, headers: { "HTTP_REFERER" => root_url }
      assert_redirected_to root_url
      assert_equal "accepted", cookies[:cookie_consent]
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end
end
