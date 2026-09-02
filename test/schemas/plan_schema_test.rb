require "test_helper"

# These assertions pin the schema's SHAPE. They do NOT guard the
# `require "schematist"` in app/schemas/plan_schema.rb: under parallelize +
# random order, any test touching CreateApplication loads RubyLLM::Tool, which
# requires schematist for the rest of the process -- so this file resolves
# PlanSchema either way. What actually guards that require is
# `config.eager_load = ENV["CI"].present?` in config/environments/test.rb: on CI
# the app eager-loads and `class PlanSchema < Schematist::Schema` fails at
# definition time without it. Locally (eager_load off) its removal passes.
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
