require "test_helper"

class StartGenerationTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Todo")
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "simple todo list")
    @tool = StartGeneration.new(project: @project)

    @plan = CreatePlan::Result.new(
      instruction_description: "A simple todo list.",
      revisions: [
        { summary: "Add Task model", prompt: "Generate a Task model with title:string and done:boolean." },
        { summary: "Add TasksController", prompt: "Generate a TasksController with index and create actions." },
        { summary: "Add index view", prompt: "Add app/views/tasks/index.html.erb with a Tailwind list." }
      ]
    )
  end

  def stub_create_plan(result_or_proc)
    original = CreatePlan.method(:call)
    CreatePlan.define_singleton_method(:call) do |**kwargs|
      result_or_proc.respond_to?(:call) ? result_or_proc.call(**kwargs) : result_or_proc
    end
    yield
  ensure
    CreatePlan.define_singleton_method(:call, original) if original
  end

  test "persists an Instruction with user_intent, description, implementing phase, and user anchor_message" do
    stub_create_plan(@plan) do
      @tool.execute(intent: "simple todo list", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal "simple todo list", instruction.user_intent
    assert_equal "A simple todo list.", instruction.description
    assert_equal "implementing", instruction.phase
    assert_equal @user_message, instruction.anchor_message
  end

  test "persists N Revisions chained via parent with correct position and status" do
    stub_create_plan(@plan) do
      @tool.execute(intent: "simple todo list", clarifications: {})
    end

    revisions = @project.instructions.order(:id).last.revisions.order(:position)
    assert_equal 3, revisions.size

    revisions.each_with_index do |rev, i|
      assert_equal i, rev.position
      assert_equal "pending", rev.status
      assert_equal @plan.revisions[i][:summary], rev.summary
      assert_equal @plan.revisions[i][:prompt], rev.prompt
    end

    assert_nil revisions[0].parent
    assert_equal revisions[0], revisions[1].parent
    assert_equal revisions[1], revisions[2].parent
  end

  test "emits instruction.requested notification with instruction_id" do
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
      payloads << payload
    end

    stub_create_plan(@plan) do
      @tool.execute(intent: "simple todo list", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal 1, payloads.size
    assert_equal instruction.id, payloads.first[:instruction_id]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "returns a Hash with instruction_id, revision_count, instruction_description" do
    result = nil
    stub_create_plan(@plan) do
      result = @tool.execute(intent: "simple todo list", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal(
      { instruction_id: instruction.id, revision_count: 3, instruction_description: "A simple todo list." },
      result
    )
  end

  test "on CreatePlan InvalidResponse: returns error hash, persists nothing, no notification" do
    raising = ->(**) { raise CreatePlan::AdHocLLM::InvalidResponse, "empty revisions" }
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| payloads << p }

    result = nil
    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_create_plan(raising) do
          result = @tool.execute(intent: "x", clarifications: {})
        end
      end
    end

    assert_match(/Could not generate a plan/, result[:error])
    assert_empty payloads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "on unexpected error from CreatePlan: propagates and persists nothing" do
    raising = ->(**) { raise RuntimeError, "upstream boom" }

    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_create_plan(raising) do
          assert_raises(RuntimeError) { @tool.execute(intent: "x", clarifications: {}) }
        end
      end
    end
  end
end
