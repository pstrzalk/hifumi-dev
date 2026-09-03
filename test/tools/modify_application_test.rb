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

  teardown do
    FileUtils.rm_rf(@project.workspace_path) if File.exist?(@project.workspace_path)
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

  def stub_app_state_build(proc)
    original = AppState.method(:build)
    AppState.define_singleton_method(:build) { |**kwargs| proc.call(**kwargs) }
    yield
  ensure
    AppState.define_singleton_method(:build, original) if original
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

  test "on malformed plan JSON: returns error hash, persists nothing, no notification" do
    # RubyLLM v2's Message#parsed raises instead of degrading to a String, and
    # nothing may escape #execute — an exception here would leave a persisted
    # tool_use with no tool_result, which permanently breaks the chat.
    raising = ->(**) { raise JSON::ParserError, "unexpected token at 'not json'" }
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

  # Was: assert_raises(RuntimeError). Propagation is precisely what orphans the
  # tool_use -- and ChatRespondJob:30 rescues StandardError anyway, so the
  # exception never reached an operator; it only killed the chat. #execute now
  # reports and returns an error hash so the tool_use still gets a tool_result.
  test "on unexpected error from PlanApplicationModification: reports it, returns an error hash, persists nothing" do
    raising = ->(**) { raise RuntimeError, "upstream boom" }
    result = nil

    reports = capture_error_reports(RuntimeError) do
      assert_no_difference -> { Instruction.count } do
        assert_no_difference -> { Revision.count } do
          stub_planner(raising) do
            result = @tool.execute(intent: "x", clarifications: {})
          end
        end
      end
    end

    assert_match(/Could not generate a modification plan/, result[:error])
    assert_equal [ "upstream boom" ], reports.map { |r| r.error.message }
  end

  # ---- context[:app_state]: the workspace snapshot fed to the planner ----

  test "passes the workspace snapshot to the planner as context[:app_state]" do
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), File.read(Rails.root.join("lib/preview/skeleton/Gemfile")))
    FileUtils.mkdir_p(File.join(@project.workspace_path, "app/models"))
    File.write(File.join(@project.workspace_path, "app/models/story.rb"), "class Story < ApplicationRecord; end\n")

    captured = nil
    capturing = ->(**kwargs) { captured = kwargs; @plan }

    stub_planner(capturing) do
      @tool.execute(intent: "make the primary color teal", clarifications: {})
    end

    assert_kind_of String, captured[:context][:app_state]
    assert_includes captured[:context][:app_state], "## Current application state"
    assert_includes captured[:context][:app_state], "app/models/story.rb"
    assert_equal "make the primary color teal", captured[:intent]
  end

  test "with no workspace on disk, context[:app_state] is nil and the plan still persists" do
    refute @project.workspace_initialized?

    captured = nil
    capturing = ->(**kwargs) { captured = kwargs; @plan }

    assert_difference -> { Instruction.count }, 1 do
      assert_difference -> { Revision.count }, 1 do
        stub_planner(capturing) do
          @tool.execute(intent: "make the primary color teal", clarifications: {})
        end
      end
    end

    assert_nil captured[:context][:app_state]
  end

  # The file reads happen inside #execute so that the rescue StandardError
  # backstop covers them: an unreadable workspace file must degrade to an error
  # hash (the tool_use still gets its tool_result) rather than escape and kill
  # the chat. This is the path that made the backstop necessary.
  test "an unreadable workspace file reaches the backstop: error hash, report, nothing persisted" do
    # Stubbed rather than chmod 000: root ignores file modes, so the chmod form
    # skipped in a root container. What this pins is that AppState.build is
    # called inside #execute's rescue, not how the read fails.
    planner_called = false
    result = nil
    reports = capture_error_reports(Errno::EACCES) do
      assert_no_difference -> { Instruction.count } do
        assert_no_difference -> { Revision.count } do
          stub_app_state_build(->(**) { raise Errno::EACCES, "Gemfile" }) do
            stub_planner(->(**) { planner_called = true; @plan }) do
              result = @tool.execute(intent: "x", clarifications: {})
            end
          end
        end
      end
    end

    refute planner_called, "the planner must not be called when the snapshot cannot be read"
    assert_match(/Could not generate a modification plan/, result[:error])
    assert_equal 1, reports.size
    assert_equal @project.id, reports.first.context[:project_id]
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
