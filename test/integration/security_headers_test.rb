require "test_helper"

class SecurityHeadersTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
  end

  # Origin-Agent-Cluster: ?1 disables the legacy document.domain setter so the
  # generator and an untrusted preview subdomain can never relax the same-origin
  # policy to the shared parent. Asserted on a plain marketing response.
  test "every response advertises an origin-keyed agent cluster" do
    get root_path
    assert_response :success
    assert_equal "?1", response.headers["Origin-Agent-Cluster"]
  end
end
