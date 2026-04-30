require "test_helper"

class CreatePlanTest < ActiveSupport::TestCase
  setup do
    @original_implementation = CreatePlan.implementation
  end

  teardown do
    CreatePlan.implementation = @original_implementation
  end

  test "default implementation is AdHocLLM" do
    CreatePlan.instance_variable_set(:@implementation, nil)
    assert_equal CreatePlan::AdHocLLM, CreatePlan.implementation
  end

  test "delegates call to the configured implementation with same args" do
    fake = Class.new do
      class << self
        attr_reader :received

        def call(**kwargs)
          @received = kwargs
          CreatePlan::Result.new(instruction_description: "fake", revisions: [{ summary: "s", prompt: "p" }])
        end
      end
    end

    CreatePlan.implementation = fake
    CreatePlan.call(
      intent: "todo list",
      clarifications: { "x" => "y" },
      context: { project_id: 1 },
      openrouter_api_key: "sk-or-test"
    )

    assert_equal(
      { intent: "todo list", clarifications: { "x" => "y" }, context: { project_id: 1 }, openrouter_api_key: "sk-or-test" },
      fake.received
    )
  end

  test "implementation= swaps the active implementation" do
    other = Module.new do
      def self.call(**)
        CreatePlan::Result.new(instruction_description: "other", revisions: [{ summary: "s", prompt: "p" }])
      end
    end

    CreatePlan.implementation = other
    result = CreatePlan.call(intent: "x", openrouter_api_key: "sk-or-test")
    assert_equal "other", result.instruction_description
  end
end
