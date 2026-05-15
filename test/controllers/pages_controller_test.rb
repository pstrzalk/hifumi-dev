require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  # Set/restore directly. `Rails.application.config` is an OrderedOptions
  # with a method_missing accessor, so Minitest's `.stub` against the
  # symbol `:operator` is fragile.
  setup do
    @original_operator = Rails.application.config.operator
  end

  teardown do
    Rails.application.config.operator = @original_operator
  end

  test "GET /privacy renders" do
    get privacy_path
    assert_response :success
    assert_select "h1", text: /Privacy/
    assert_select "h2", text: "What we store"
  end

  test "last-updated date is hardcoded, not Date.current" do
    travel_to Date.new(2027, 8, 1) do
      get privacy_path
      assert_select ".lede", text: /Last updated: May 15, 2026/
      refute_match(/August 2027/, response.body, "last-updated must not drift with the clock")
    end
  end

  test "operator block falls back to a notice when ENV vars are unset" do
    Rails.application.config.operator = { name: nil, tax_id: nil, business_registration_url: nil, contact_email: nil }
    get privacy_path
    assert_select ".notice-strip--warn"
  end

  test "operator block renders when ENV vars are set" do
    Rails.application.config.operator = {
      name: "Acme",
      tax_id: "PL1234567890",
      business_registration_url: "https://example.com/reg",
      contact_email: "ops@example.com"
    }
    get privacy_path
    assert_select "strong", text: "Acme"
  end
end
