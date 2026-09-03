require "test_helper"
require "shellwords"

# E2E acceptance for Phase 2's W1+W2 happy path: a user message goes through
# ProjectsController → ChatRespondJob → CreateApplication → ExecuteInstructionJob,
# the real `bin/roast` subprocess runs three revisions, and the generated app's
# own test suite is green.
#
# Stubbed, so no tokens are spent on the LLM layers a real run would consult:
# - `Chat#complete` (chat-LLM) — a real LLM would call CreateApplication with
#   whatever intent the user typed; we short-circuit to that decision.
# - `PlanApplicationCreation.implementation` (plan-LLM) — the deterministic
#   three-revision todo_list fixture.
# - `Templates::Picker.pick` (template-LLM, the one RubyLLM call on the W2 side)
#   — pinned to one template; `apply` stays real so frontend.md and the font
#   <link> land in the workspace exactly as in production.
#
# Real: ExecuteInstructionJob, including the `bin/roast` subprocess that calls
# the Claude CLI for each revision. Wall time ≈ 9 minutes (550s measured
# 2026-09-03, ~900s seen in May); bounded at 1200s.
#
# Gated by E2E_GENERATE=1 so the default `bin/rails test` stays fast.
class GenerateTodoListTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  PROMPT = "Simple todo list, Tailwind".freeze
  WALL_TIME_BUDGET = 1200
  TEMPLATE = "office"

  setup do
    skip "set E2E_GENERATE=1 to run (real bin/roast subprocess, ~8 min, burns Claude tokens)" unless ENV["E2E_GENERATE"] == "1"

    # ProjectsController has required a signed-in user since Phase 4. The fake
    # OpenRouter key on this user is never sent anywhere: every RubyLLM-backed
    # stage on this path is stubbed below, and the W2 implementer runs on the
    # Claude-subscription transport outside production.
    @user = create_user
    sign_in @user

    require Rails.root.join("test/fixtures/plans/todo_list.rb").to_s
    @original_create_plan = PlanApplicationCreation.implementation
    PlanApplicationCreation.implementation = fake_plan_returning(PlanFixtures.todo_list)
    stub_template_pick!
    stub_chat_complete!
  end

  teardown do
    restore_chat_complete!
    restore_template_pick!
    PlanApplicationCreation.implementation = @original_create_plan if @original_create_plan
  end

  test "Simple todo list, Tailwind: 3 revisions complete and workspace tests green" do
    started = Time.current
    # Only the two jobs the pipeline consists of. StopPreviewJob (fired by
    # instruction.requested) would drive Docker for a preview that was never
    # started, and the Turbo broadcast jobs have no subscriber here.
    perform_enqueued_jobs(only: [ ChatRespondJob, ExecuteInstructionJob ]) do
      post projects_path, params: { project: { description: PROMPT } }
    end
    elapsed = Time.current - started

    # Scoped to the signed-in user: fixtures load projects with large hashed
    # ids, so Project.order(:id).last returns a fixture, never the row this
    # request created.
    project = @user.projects.sole
    instruction = project.instructions.sole

    assert_predicate instruction.reload, :completed?, "instruction phase: #{instruction.phase}"
    assert_equal 3, project.revisions.count
    assert project.revisions.all?(&:completed?),
      "expected all revisions completed, got #{project.revisions.order(:position).map(&:status)}"

    # Before the generated app's own suite runs: a blown budget is the answer
    # already, no need to spend another minute finding out.
    assert_operator elapsed, :<, WALL_TIME_BUDGET,
      "generation took #{elapsed.round}s, exceeds #{WALL_TIME_BUDGET}s budget"

    workspace = project.workspace_path
    # Presence, not the H1: the W2.6 docs agent may edit frontend.md on a styling
    # revision, and this asserts that `apply` wrote the pinned template, not
    # that the heading survived three revisions untouched.
    assert_includes File.read(File.join(workspace, "docs/frontend.md")), TEMPLATE
    assert_workspace_git_log_at_least(workspace, 4)
    assert_workspace_tests_pass(workspace)
  end

  private

  def fake_plan_returning(result)
    Class.new do
      define_singleton_method(:call) { |**| result }
    end
  end

  # Reaches GeneratorAgent#complete via Forwardable (RubyLLM::Agent delegates
  # `complete` to the chat record), so redefining Chat#complete is sufficient.
  #
  # Two turns reach it. The user's first message becomes the CreateApplication
  # call a real LLM would make from that intent. The second is the auto-recap
  # nudge that the instruction.completed subscriber injects — the real prompt
  # forbids tool calls on that turn, so it is a text-only assistant message here
  # too. Without that branch the stub would start a second, identical build.
  def stub_chat_complete!
    Chat.class_eval do
      alias_method :_original_complete_for_e2e, :complete unless method_defined?(:_original_complete_for_e2e)
      define_method(:complete) do |**_kwargs, &_block|
        if project.instructions.none?
          latest_user = messages.where(role: :user, system_injected: false).order(:id).last
          CreateApplication.new(project: project).execute(intent: latest_user.content.to_s, clarifications: {})
        else
          messages.create!(role: :assistant, content: "The todo list is built. What would you like to change next?")
        end
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

  def stub_template_pick!
    @original_pick = Templates::Picker.method(:pick)
    Templates::Picker.define_singleton_method(:pick) { |**| TEMPLATE }
  end

  def restore_template_pick!
    Templates::Picker.define_singleton_method(:pick, @original_pick) if @original_pick
  end

  def assert_workspace_git_log_at_least(workspace, expected)
    log = `cd #{Shellwords.escape(workspace)} && git log --oneline 2>/dev/null`.lines
    assert_operator log.size, :>=, expected,
      "expected >= #{expected} commits in workspace, got #{log.size}:\n#{log.join}"
  end

  def assert_workspace_tests_pass(workspace)
    ruby_version = File.read(Rails.root.join(".ruby-version")).strip.delete_prefix("ruby-")
    frum_bin = File.join(Dir.home, ".frum", "versions", ruby_version, "bin")
    env = File.directory?(frum_bin) ? { "PATH" => "#{frum_bin}:#{ENV.fetch('PATH', '')}" } : {}

    ok = nil
    Bundler.with_unbundled_env do
      ok = system(env, "cd #{Shellwords.escape(workspace)} && bin/rails test", %i[out err] => File::NULL)
    end
    assert ok, "bin/rails test failed in workspace #{workspace}"
  end
end
