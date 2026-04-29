require "test_helper"

class Preview::ConfigTest < ActiveSupport::TestCase
  setup do
    @original_domain = Rails.configuration.preview.domain
  end

  teardown do
    Rails.configuration.preview.domain = @original_domain
  end

  test "remote? is false when domain is nil" do
    Rails.configuration.preview.domain = nil
    assert_not Preview::Config.remote?
  end

  test "remote? is true and domain returns the value when set" do
    Rails.configuration.preview.domain = "hifumi.dev"
    assert Preview::Config.remote?
    assert_equal "hifumi.dev", Preview::Config.domain
  end

  test "port_offset returns the configured value" do
    assert_equal 3000, Preview::Config.port_offset
  end
end
