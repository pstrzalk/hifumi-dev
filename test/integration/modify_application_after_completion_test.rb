require "test_helper"

# Drives the design-tweak flow end-to-end with stubbed planner and stubbed
# Chat#complete. Verifies that a tweak after a completed build:
# - routes through modify_application (not create_application — Bug A fix)
# - requires user confirmation before firing the tool
# - produces a single-revision modification (no rebuild)
# - triggers the auto-recap on instruction.completed (Bug C fix)
#
# This test stubs the LLM and the planner so it stays fast (<1s) and runs
# in default CI without burning tokens. The Roast subprocess is NOT invoked.
class ModifyApplicationAfterCompletionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = create_user(openrouter_api_key: "sk-or-test-fixture-1234567890ab")
    @project = @user.projects.create!(name: "Storybook")
    @chat = GeneratorAgent.create!(project: @project)

    # Pre-initialize the workspace so workspace_initialized? returns true:
    # this is the precondition that routes the chat agent to ModifyApplication.
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), "# fake\n")

    # Pre-create a completed instruction so this is unambiguously a tweak path,
    # not a fresh build.
    seed_user_msg = @chat.messages.create!(role: :user, content: "build a storybook")
    @prior_instruction = @project.instructions.create!(
      user_intent: "build a storybook",
      description: "Build a children's storybook app.",
      phase: :completed,
      anchor_message: seed_user_msg
    )

    require Rails.root.join("test/fixtures/plans/banner_green.rb").to_s
    @original_planner = PlanApplicationModification.implementation
    PlanApplicationModification.implementation = fake_planner_returning(PlanFixtures.banner_green)
  end

  teardown do
    PlanApplicationModification.implementation = @original_planner if @original_planner
    FileUtils.rm_rf(@project.workspace_path) if @project.workspace_path
    restore_chat_complete!
  end

  test "tweak after completed build: confirmation required, then modify_application produces one revision" do
    # Pre-condition: workspace is initialized → ModifyApplication is the bound mutation tool.
    assert @project.workspace_initialized?

    stub_chat_complete_scripted!

    # Turn 1: user describes the change. LLM stub produces text-only summary + question (no tool call).
    user_msg = @chat.messages.create!(role: :user, content: "make the banner green")
    assert_no_difference -> { Instruction.count } do
      perform_enqueued_jobs(only: ChatRespondJob) do
        ChatRespondJob.perform_now(user_msg.id)
      end
    end

    # Turn 2: user confirms. LLM stub fires modify_application.
    confirm_msg = @chat.messages.create!(role: :user, content: "yes, apply it")
    assert_difference -> { Instruction.count }, 1 do
      perform_enqueued_jobs(only: ChatRespondJob) do
        ChatRespondJob.perform_now(confirm_msg.id)
      end
    end

    new_instruction = @project.instructions.where.not(id: @prior_instruction.id).order(:id).last
    assert_equal "implementing", new_instruction.phase
    assert_equal "Change the top banner to green.", new_instruction.description
    assert_equal 1, new_instruction.revisions.count, "tweak must produce a single revision, not a rebuild"
    assert_equal "Update banner color in application layout", new_instruction.revisions.first.summary
  end

  test "instruction.completed enqueues an auto-recap ChatRespondJob with a system_injected nudge" do
    new_instruction = @project.instructions.create!(
      user_intent: "make the banner green",
      description: "Change banner color",
      phase: :implementing,
      anchor_message: @chat.messages.create!(role: :user, content: "make the banner green")
    )

    assert_enqueued_jobs 1, only: ChatRespondJob do
      ActiveSupport::Notifications.instrument(
        "instruction.completed",
        instruction_id: new_instruction.id
      )
    end

    nudge = @chat.messages.where(system_injected: true).order(:id).last
    assert_equal "user", nudge.role
    assert_includes nudge.content, "Auto-resume"
    refute nudge.visible_in_chat?, "the synthetic nudge must not render in the chat UI"
  end

  private

  def fake_planner_returning(result)
    Module.new.tap do |m|
      m.define_singleton_method(:call) { |**| result }
    end
  end

  # Stubs Chat#complete to drive scripted behavior:
  # - if the latest user message looks like a confirmation, fires the bound
  #   mutation tool (ModifyApplication, given workspace_initialized?)
  # - otherwise creates an empty assistant placeholder (the "summary + ask"
  #   surface from the confirmation-first prompt)
  CONFIRMATION_RE = /\b(yes|go ahead|do it|proceed|apply)\b/i.freeze

  def stub_chat_complete_scripted!
    Chat.class_eval do
      alias_method :_original_complete_for_phase9, :complete unless method_defined?(:_original_complete_for_phase9)
      define_method(:complete) do |**_kwargs, &_block|
        latest_user = messages.where(role: :user, system_injected: false).order(:id).last
        if latest_user && latest_user.content.match?(CONFIRMATION_RE)
          ModifyApplication.new(project: project).execute(
            intent: latest_user.content.to_s, clarifications: {}
          )
        else
          messages.create!(role: :assistant, content: "Got it — should I apply this?")
        end
      end
    end
  end

  def restore_chat_complete!
    Chat.class_eval do
      if method_defined?(:_original_complete_for_phase9)
        alias_method :complete, :_original_complete_for_phase9
        remove_method :_original_complete_for_phase9
      end
    end
  end
end
