require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "anon at / renders welcome with both CTAs" do
    get root_path
    assert_response :success
    assert_select "a", text: "Sign up"
    assert_select "a", text: "Log in"
  end

  test "logged-in at / redirects to /projects" do
    sign_in create_user
    get root_path
    assert_redirected_to projects_path
  end
end
