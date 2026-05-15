require "test_helper"

class FooterTest < ActionDispatch::IntegrationTest
  setup do
    # Footer renders without consent (it's static chrome with no session reads),
    # but seeding consent keeps these tests consistent with the rest of the suite
    # and lets a future change use session-backed helpers safely.
    cookies[:cookie_consent] = "accepted"
  end

  test "footer renders on root" do
    get root_path
    assert_select "footer.app-footer"
  end

  test "footer renders on privacy" do
    get privacy_path
    assert_select "footer.app-footer"
  end

  test "footer renders on contact" do
    get contact_path
    assert_select "footer.app-footer"
  end

  test "footer links resolve" do
    get root_path
    assert_select "footer.app-footer a[href=?]", privacy_path, text: "Privacy"
    assert_select "footer.app-footer a[href=?]", contact_path, text: "Contact"
    assert_select "footer.app-footer a[href*=?]", "github.com/pstrzalk/hifumi-dev", text: "GitHub"
    assert_select "footer.app-footer a[href*=?]", "LICENSE", text: "License"
  end

  test "footer copyright shows current year" do
    get root_path
    assert_select ".app-footer__copyright", text: /#{Date.current.year}/
  end
end
