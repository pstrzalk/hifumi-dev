require "test_helper"

class PlanApplicationCreationTest < ActiveSupport::TestCase
  setup do
    @original_implementation = PlanApplicationCreation.implementation
  end

  teardown do
    PlanApplicationCreation.implementation = @original_implementation
  end

  test "default implementation is AdHocLLM" do
    PlanApplicationCreation.instance_variable_set(:@implementation, nil)
    assert_equal PlanApplicationCreation::AdHocLLM, PlanApplicationCreation.implementation
  end

  test "delegates call to the configured implementation with same args" do
    fake = Class.new do
      class << self
        attr_reader :received

        def call(**kwargs)
          @received = kwargs
          PlanApplicationCreation::Result.new(instruction_description: "fake", revisions: [ { summary: "s", prompt: "p" } ])
        end
      end
    end

    PlanApplicationCreation.implementation = fake
    PlanApplicationCreation.call(
      intent: "todo list",
      clarifications: { "x" => "y" },
      context: { project_id: 1 },
      openrouter_api_key: "sk-or-test",
      model: "anthropic/claude-haiku-4.5"
    )

    assert_equal(
      { intent: "todo list", clarifications: { "x" => "y" }, context: { project_id: 1 }, openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5" },
      fake.received
    )
  end

  test "implementation= swaps the active implementation" do
    other = Module.new do
      def self.call(**)
        PlanApplicationCreation::Result.new(instruction_description: "other", revisions: [ { summary: "s", prompt: "p" } ])
      end
    end

    PlanApplicationCreation.implementation = other
    result = PlanApplicationCreation.call(intent: "x", openrouter_api_key: "sk-or-test", model: "anthropic/claude-haiku-4.5")
    assert_equal "other", result.instruction_description
  end
end
