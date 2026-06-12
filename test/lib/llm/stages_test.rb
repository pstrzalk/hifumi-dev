require "test_helper"

class LLM::StagesTest < ActiveSupport::TestCase
  test "stage keys are unique" do
    keys = LLM::Stages::ALL.map(&:key)
    assert_equal keys.uniq, keys
  end

  test "every stage default_model is an available model" do
    LLM::Stages::ALL.each do |stage|
      assert_includes LLM::Stages::AVAILABLE_MODELS.keys, stage.default_model,
        "stage #{stage.key} defaults to a model missing from AVAILABLE_MODELS"
    end
  end

  test "find returns the stage for a symbol or string key" do
    assert_equal :code, LLM::Stages.find(:code).key
    assert_equal :code, LLM::Stages.find("code").key
  end

  test "find raises KeyError for an unknown key" do
    assert_raises(KeyError) { LLM::Stages.find(:nonexistent) }
  end

  test "every project_column is a real Project attribute" do
    LLM::Stages.project_columns.each do |column|
      assert_includes Project.column_names, column.to_s,
        "projects table is missing #{column} — registry and schema drifted"
    end
  end

  test "every profile_column is a real Profile attribute" do
    LLM::Stages.profile_columns.each do |column|
      assert_includes Profile.column_names, column.to_s,
        "profiles table is missing #{column} — registry and schema drifted"
    end
  end

  test "schema defaults match the registry defaults on both tables" do
    LLM::Stages::ALL.each do |stage|
      assert_equal stage.default_model, Project.column_defaults[stage.project_column.to_s],
        "projects.#{stage.project_column} DB default drifted from the registry"
      assert_equal stage.default_model, Profile.column_defaults[stage.profile_column.to_s],
        "profiles.#{stage.profile_column} DB default drifted from the registry"
    end
  end
end
