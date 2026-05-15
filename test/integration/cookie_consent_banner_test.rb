require "test_helper"

class CookieConsentBannerTest < ActionDispatch::IntegrationTest
  test "banner partial renders on the root page" do
    get root_path
    assert_select "[data-controller='cookie-consent']"
    assert_select ".cookie-bar__panel.is-hidden", count: 1
    assert_select "button[data-action='click->cookie-consent#decline']"
    assert_select "form[action=?][method=?]", cookie_consent_path, "post"
    assert_select "form[action=?] input[type=submit][data-action='click->cookie-consent#accept']", cookie_consent_path
  end

  test "banner partial renders on /privacy" do
    get privacy_path
    assert_select "[data-controller='cookie-consent']"
  end

  test "banner copy links to the privacy page" do
    get root_path
    assert_select ".cookie-bar__copy a[href=?]", privacy_path
  end
end
