require "test_helper"

class ModifyApplicationTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "Storybook", user: users(:owner))
    @chat = @project.create_chat!
    @user_message = @chat.messages.create!(role: :user, content: "make the primary color teal")
    @tool = ModifyApplication.new(project: @project)

    @plan = PlanApplicationModification::Result.new(
      instruction_description: "Set primary color to teal.",
      revisions: [
        {
          summary: "Update primary color to teal",
          prompt: "In app/assets/tailwind/application.css, change --accent to a teal hex."
        }
      ]
    )
  end

  def stub_planner(result_or_proc)
    original = PlanApplicationModification.method(:call)
    PlanApplicationModification.define_singleton_method(:call) do |**kwargs|
      result_or_proc.respond_to?(:call) ? result_or_proc.call(**kwargs) : result_or_proc
    end
    yield
  ensure
    PlanApplicationModification.define_singleton_method(:call, original) if original
  end

  test "persists an Instruction with user_intent, description, implementing phase, and user anchor_message" do
    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal "make the primary color teal", instruction.user_intent
    assert_equal "Set primary color to teal.", instruction.description
    assert_equal "implementing", instruction.phase
    assert_equal @user_message, instruction.anchor_message
  end

  test "persists a single Revision with position 0 and status pending" do
    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    revisions = @project.instructions.order(:id).last.revisions.order(:position)
    assert_equal 1, revisions.size
    assert_equal 0, revisions.first.position
    assert_equal "pending", revisions.first.status
    assert_equal @plan.revisions.first[:summary], revisions.first.summary
    assert_equal @plan.revisions.first[:prompt], revisions.first.prompt
    assert_nil revisions.first.parent
  end

  test "persists multiple Revisions chained via parent for a multi-revision modification plan" do
    multi = PlanApplicationModification::Result.new(
      instruction_description: "Replace storybook with kanban board.",
      revisions: [
        { summary: "Add Board model", prompt: "..." },
        { summary: "Add BoardsController + routes", prompt: "..." },
        { summary: "Add Tailwind kanban views", prompt: "..." }
      ]
    )

    stub_planner(multi) do
      @tool.execute(intent: "replace storybook with a kanban board", clarifications: {})
    end

    revisions = @project.instructions.order(:id).last.revisions.order(:position)
    assert_equal 3, revisions.size
    assert_nil revisions[0].parent
    assert_equal revisions[0], revisions[1].parent
    assert_equal revisions[1], revisions[2].parent
  end

  test "emits instruction.requested notification with instruction_id" do
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") do |*, payload|
      payloads << payload
    end

    stub_planner(@plan) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal 1, payloads.size
    assert_equal instruction.id, payloads.first[:instruction_id]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "returns a Hash with instruction_id, revision_count, instruction_description" do
    result = nil
    stub_planner(@plan) do
      result = @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    instruction = @project.instructions.order(:id).last
    assert_equal(
      { instruction_id: instruction.id, revision_count: 1, instruction_description: "Set primary color to teal." },
      result
    )
  end

  test "on PlanApplicationModification InvalidResponse: returns error hash, persists nothing, no notification" do
    raising = ->(**) { raise PlanApplicationModification::AdHocLLM::InvalidResponse, "empty revisions" }
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| payloads << p }

    result = nil
    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_planner(raising) do
          result = @tool.execute(intent: "x", clarifications: {})
        end
      end
    end

    assert_match(/Could not generate a modification plan/, result[:error])
    assert_empty payloads
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "on unexpected error from PlanApplicationModification: propagates and persists nothing" do
    raising = ->(**) { raise RuntimeError, "upstream boom" }

    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_planner(raising) do
          assert_raises(RuntimeError) { @tool.execute(intent: "x", clarifications: {}) }
        end
      end
    end
  end

  test "refuses and persists nothing when an implementing instruction already exists" do
    @project.instructions.create!(
      user_intent: "earlier", description: "earlier",
      phase: :implementing, anchor_message: @user_message
    )

    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("instruction.requested") { |*, p| payloads << p }

    result = nil
    assert_no_difference -> { Instruction.count } do
      assert_no_difference -> { Revision.count } do
        stub_planner(@plan) do
          result = @tool.execute(intent: "second change", clarifications: {})
        end
      end
    end

    assert result[:error].present?, "expected refusal to include an :error key"
    assert_match(/already in progress/, result[:error])
    assert_equal 0, payloads.size, "expected no instruction.requested notification"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "does not refuse when all prior instructions are terminal" do
    @project.instructions.create!(
      user_intent: "earlier", description: "earlier",
      phase: :completed, anchor_message: @user_message
    )

    stub_planner(@plan) do
      result = @tool.execute(intent: "second change", clarifications: {})
      assert result[:instruction_id].present?
      refute result.key?(:error)
    end
  end
end
