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

    # Must stay in step with app/prompts/plan_application_creation_system.md:4 --
    # the model reads both, and a disagreement is a contradictory instruction.
    # Neither bound is enforced: no min_items/max_items is passed, so this is
    # the description text the model sees, not a schema constraint.
    assert_equal "Ordered list of 4 to 8 atomic revisions.", revisions["description"]
  end
end
