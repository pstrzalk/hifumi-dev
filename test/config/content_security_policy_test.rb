require "test_helper"

# Verifies the frame-src branch in config/initializers/content_security_policy.rb
# routes correctly per ENV["PREVIEW_DOMAIN"]. The initializer mutates the shared
# policy object in place each time it is loaded, so each test sets ENV, reloads,
# and asserts. teardown reloads once more under the original ENV to restore.
class ContentSecurityPolicyTest < ActiveSupport::TestCase
  CSP_INITIALIZER = Rails.root.join("config/initializers/content_security_policy.rb").freeze

  setup do
    @original_env = ENV["PREVIEW_DOMAIN"]
  end

  teardown do
    if @original_env.nil?
      ENV.delete("PREVIEW_DOMAIN")
    else
      ENV["PREVIEW_DOMAIN"] = @original_env
    end
    load CSP_INITIALIZER
  end

  test "frame-src contains https://*.preview.<PREVIEW_DOMAIN> when set" do
    ENV["PREVIEW_DOMAIN"] = "hifumi.dev"
    load CSP_INITIALIZER

    frame_src = Rails.application.config.content_security_policy.directives["frame-src"]
    assert_includes frame_src, "https://*.preview.hifumi.dev"
  end

  test "frame-src falls back to http://localhost:* in dev (no PREVIEW_DOMAIN)" do
    ENV.delete("PREVIEW_DOMAIN")
    load CSP_INITIALIZER

    frame_src = Rails.application.config.content_security_policy.directives["frame-src"]
    assert_includes frame_src, "http://localhost:*"
  end
end
