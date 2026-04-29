require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "create without profile fails with Profile can't be blank" do
    user = User.new(email: "x@y.z", password: "password123")
    assert_not user.save
    assert_includes user.errors[:profile], "can't be blank"
  end

  test "create with nested profile_attributes succeeds and persists profile" do
    user = User.create!(
      email: "test1@example.com",
      password: "password123",
      profile_attributes: {
        first_name: "Pat",
        last_name: "Smith",
        openrouter_api_key: "sk-or-test-1234567890abcd"
      }
    )
    assert user.persisted?
    assert user.profile.persisted?
    assert_equal "Pat", user.profile.first_name
    assert_equal "sk-or-test-1234567890abcd", user.profile.openrouter_api_key
  end

  test "create with built-but-invalid profile fails validation" do
    user = User.new(email: "test2@example.com", password: "password123")
    user.build_profile(first_name: "Pat", last_name: "Smith") # missing key
    assert_not user.save
    assert_includes user.errors["profile.openrouter_api_key"], "can't be blank"
  end
end
