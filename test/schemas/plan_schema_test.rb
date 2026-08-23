require "test_helper"

class PlanSchemaTest < ActiveSupport::TestCase
  # The only test that resolves PlanSchema at all. Both AdHocLLM suites stub
  # invoke_llm above the schema, so without this a missing `require
  # "schematist"` or a wrong superclass only surfaces at runtime.
  test "builds a JSON Schema document with the fields build_result reads" do
    doc = PlanSchema.new.to_json_schema

    assert_equal "object", doc["type"]
    assert_equal "string", doc.dig("properties", "instruction_description", "type")

    revisions = doc.dig("properties", "revisions")
    assert_equal "array", revisions["type"]
    assert_equal %w[prompt summary], revisions.dig("items", "properties").keys.sort
  end
end
