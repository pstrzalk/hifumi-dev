require "test_helper"

class PlanApplicationModificationTest < ActiveSupport::TestCase
  setup do
    @original_implementation = PlanApplicationModification.implementation
  end

  teardown do
    PlanApplicationModification.implementation = @original_implementation
  end

  test "default implementation is AdHocLLM" do
    PlanApplicationModification.instance_variable_set(:@implementation, nil)
    assert_equal PlanApplicationModification::AdHocLLM, PlanApplicationModification.implementation
  end

  test "delegates call to the configured implementation with same args" do
    fake = Class.new do
      class << self
        attr_reader :received

        def call(**kwargs)
          @received = kwargs
          PlanApplicationModification::Result.new(instruction_description: "fake", revisions: [{ summary: "s", prompt: "p" }])
        end
      end
    end

    PlanApplicationModification.implementation = fake
    PlanApplicationModification.call(
      intent: "make banner green",
      clarifications: { "x" => "y" },
      context: { project_id: 1 },
      openrouter_api_key: "sk-or-test"
    )

    assert_equal(
      { intent: "make banner green", clarifications: { "x" => "y" }, context: { project_id: 1 }, openrouter_api_key: "sk-or-test" },
      fake.received
    )
  end

  test "implementation= swaps the active implementation" do
    other = Module.new do
      def self.call(**)
        PlanApplicationModification::Result.new(instruction_description: "other", revisions: [{ summary: "s", prompt: "p" }])
      end
    end

    PlanApplicationModification.implementation = other
    result = PlanApplicationModification.call(intent: "x", openrouter_api_key: "sk-or-test")
    assert_equal "other", result.instruction_description
  end
end
