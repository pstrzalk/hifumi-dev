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

  # --- per-stage default models ------------------------------------------

  test "a new profile gets the registry default model for every stage" do
    profile = create_user.profile
    LLM::Stages::ALL.each do |stage|
      assert_equal stage.default_model, profile[stage.profile_column],
        "expected #{stage.profile_column} to default to #{stage.default_model}"
    end
  end

  test "rejects a default model outside the available list" do
    profile = create_user.profile
    profile.default_code_model = "openai/gpt-4o"
    assert_not profile.valid?
    assert_includes profile.errors[:default_code_model], "is not an available model"
  end

  test "default_models_for_project maps each profile default onto its project column" do
    profile = create_user.profile
    profile.update!(default_code_model: "anthropic/claude-opus-4.6")

    mapped = profile.default_models_for_project
    assert_equal "anthropic/claude-opus-4.6", mapped[:code_model]
    assert_equal LLM::Stages.project_columns.sort, mapped.keys.sort
  end
end
