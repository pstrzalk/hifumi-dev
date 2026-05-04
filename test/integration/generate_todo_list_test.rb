require "test_helper"
require "shellwords"

# E2E acceptance for Phase 2's W1+W2 happy path: a user message goes through
# ProjectsController → ChatRespondJob → CreateApplication → ExecuteInstructionJob,
# the real `bin/roast` subprocess runs three revisions, and the generated app's
# own test suite is green.
#
# Stubbed: `Chat#complete` (chat-LLM) and `PlanApplicationCreation.implementation` (plan-LLM)
# so we don't burn tokens on those layers — a real LLM would call CreateApplication
# with whatever intent the user typed; we short-circuit to that decision.
#
# Real: ExecuteInstructionJob, including the `bin/roast` subprocess that calls
# Claude CLI for each revision. Wall time ≈ 8 minutes; bounded at 900s.
#
# Gated by E2E_GENERATE=1 so the default `bin/rails test` stays fast.
class GenerateTodoListTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PROMPT = "Simple todo list, Tailwind".freeze
  WALL_TIME_BUDGET = 900

  setup do
    skip "set E2E_GENERATE=1 to run (real bin/roast subprocess, ~8 min, burns Claude tokens)" unless ENV["E2E_GENERATE"] == "1"

    require Rails.root.join("test/fixtures/plans/todo_list.rb").to_s
    @original_create_plan = PlanApplicationCreation.implementation
    PlanApplicationCreation.implementation = fake_plan_returning(PlanFixtures.todo_list)
    stub_chat_complete!
  end

  teardown do
    restore_chat_complete!
    PlanApplicationCreation.implementation = @original_create_plan if @original_create_plan
  end

  test "Simple todo list, Tailwind: 3 revisions complete and workspace tests green" do
    started = Time.current
    perform_enqueued_jobs do
      post projects_path, params: { project: { description: PROMPT } }
    end
    elapsed = Time.current - started

    project = Project.order(:id).last
    instruction = project.instructions.order(:id).last

    assert_predicate instruction.reload, :completed?, "instruction phase: #{instruction.phase}"
    assert_equal 3, project.revisions.count
    assert project.revisions.all?(&:completed?),
      "expected all revisions completed, got #{project.revisions.order(:position).map(&:status)}"

    workspace = project.workspace_path
    assert_workspace_git_log_at_least(workspace, 4)
    assert_workspace_tests_pass(workspace)
    assert_operator elapsed, :<, WALL_TIME_BUDGET,
      "generation took #{elapsed.round}s, exceeds #{WALL_TIME_BUDGET}s budget"
  end

  private

  def fake_plan_returning(result)
    Class.new do
      define_singleton_method(:call) { |**| result }
    end
  end

  # Reaches GeneratorAgent#complete via Forwardable (RubyLLM::Agent delegates
  # `complete` to the chat record), so redefining Chat#complete is sufficient.
  def stub_chat_complete!
    Chat.class_eval do
      alias_method :_original_complete_for_e2e, :complete unless method_defined?(:_original_complete_for_e2e)
      define_method(:complete) do |**_kwargs, &_block|
        latest_user = messages.where(role: :user).order(:id).last
        CreateApplication.new(project: project).execute(intent: latest_user.content.to_s, clarifications: {})
      end
    end
  end

  def restore_chat_complete!
    Chat.class_eval do
      if method_defined?(:_original_complete_for_e2e)
        alias_method :complete, :_original_complete_for_e2e
        remove_method :_original_complete_for_e2e
      end
    end
  end

  def assert_workspace_git_log_at_least(workspace, expected)
    log = `cd #{Shellwords.escape(workspace)} && git log --oneline 2>/dev/null`.lines
    assert_operator log.size, :>=, expected,
      "expected >= #{expected} commits in workspace, got #{log.size}:\n#{log.join}"
  end

  def assert_workspace_tests_pass(workspace)
    ruby_version = File.read(Rails.root.join(".ruby-version")).strip
    frum_bin = File.join(Dir.home, ".frum", "versions", ruby_version, "bin")
    env = File.directory?(frum_bin) ? { "PATH" => "#{frum_bin}:#{ENV.fetch('PATH', '')}" } : {}

    ok = nil
    Bundler.with_unbundled_env do
      ok = system(env, "cd #{Shellwords.escape(workspace)} && bin/rails test", %i[out err] => File::NULL)
    end
    assert ok, "bin/rails test failed in workspace #{workspace}"
  end
end
