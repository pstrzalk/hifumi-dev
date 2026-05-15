require "test_helper"

class ContactMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    cookies[:cookie_consent] = "accepted"
  end

  test "GET /contact renders the form" do
    get contact_path
    assert_response :success
    assert_select "form[action=?]", contact_path
    assert_select "input[type=email][name=?]", "contact_message[email]"
    assert_select "textarea[name=?]", "contact_message[message]"
  end

  test "POST /contact with valid params creates a row and redirects to the thank-you page" do
    assert_difference "ContactMessage.count", 1 do
      post contact_path, params: { contact_message: { email: "a@b.co", message: "Long enough message body." } }
    end
    assert_redirected_to thanks_contact_path
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Thanks"
    assert_select "a[href=?]", contact_path, text: /Send another/
  end

  test "GET /contact/thanks renders the thank-you template" do
    get thanks_contact_path
    assert_response :success
    assert_select "h1", text: "Thanks"
  end

  test "POST /contact with invalid params re-renders and does not create" do
    assert_no_difference "ContactMessage.count" do
      post contact_path, params: { contact_message: { email: "bad", message: "x" } }
    end
    assert_response :unprocessable_entity
  end
end
