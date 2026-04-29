require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test "openrouter_api_key is filtered through the request param filter" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    out = filter.filter(
      "user" => {
        "profile_attributes" => { "openrouter_api_key" => "sk-or-leak1234567890abcdef" }
      }
    )
    assert_equal "[FILTERED]", out["user"]["profile_attributes"]["openrouter_api_key"]
  end

  test "anthropic_api_key is filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    out = filter.filter("anthropic_api_key" => "sk-ant-leak1234567890abcdef")
    assert_equal "[FILTERED]", out["anthropic_api_key"]
  end
end
