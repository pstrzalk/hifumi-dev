require "test_helper"

class ProfileTest < ActiveSupport::TestCase
  test "openrouter_api_key encrypts at rest, decrypts on read" do
    user = User.create!(
      email: "encrypt@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "A", last_name: "B",
        openrouter_api_key: "sk-or-secret-9999999999"
      }
    )
    raw = Profile.connection.select_value(
      "SELECT openrouter_api_key FROM profiles WHERE id = #{user.profile.id}"
    )
    assert_not_equal "sk-or-secret-9999999999", raw, "stored value should be ciphertext"
    assert_equal "sk-or-secret-9999999999", user.profile.reload.openrouter_api_key
  end
end
