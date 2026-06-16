require "test_helper"

class Preview::ConfigTest < ActiveSupport::TestCase
  setup do
    @original_domain = Rails.configuration.preview.domain
    @original_cert   = Rails.configuration.preview.tls_certificate_path
    @original_key    = Rails.configuration.preview.tls_private_key_path
  end

  teardown do
    Rails.configuration.preview.domain = @original_domain
    Rails.configuration.preview.tls_certificate_path = @original_cert
    Rails.configuration.preview.tls_private_key_path = @original_key
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

  test "wildcard_tls? is false when neither path is set" do
    Rails.configuration.preview.tls_certificate_path = nil
    Rails.configuration.preview.tls_private_key_path = nil
    assert_not Preview::Config.wildcard_tls?
  end

  test "wildcard_tls? is false when only one path is set" do
    Rails.configuration.preview.tls_certificate_path = "/proxy/certs/wildcard.crt"
    Rails.configuration.preview.tls_private_key_path = nil
    assert_not Preview::Config.wildcard_tls?
  end

  test "wildcard_tls? is true and paths are exposed when both are set" do
    Rails.configuration.preview.tls_certificate_path = "/proxy/certs/wildcard.crt"
    Rails.configuration.preview.tls_private_key_path = "/proxy/certs/wildcard.key"
    assert Preview::Config.wildcard_tls?
    assert_equal "/proxy/certs/wildcard.crt", Preview::Config.tls_certificate_path
    assert_equal "/proxy/certs/wildcard.key", Preview::Config.tls_private_key_path
  end
end
