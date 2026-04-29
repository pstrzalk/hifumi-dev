require "test_helper"
require "shellwords"
require "tmpdir"

# E2E acceptance for Phase 3's preview pipeline. Exercises the full Docker
# chain: skeleton workspace → real `docker build` → `docker run` → curl `/up`
# → `docker rm`. No LLM calls — pure local Docker work.
#
# Requires the base image (`bin/preview-rebuild-base`) to exist before running.
#
# Gated by E2E_PREVIEW=1 so the default `bin/rails test` stays fast and works
# on machines without Docker (CI without preview-base will skip cleanly).
class PreviewLifecycleTest < ActionDispatch::IntegrationTest
  WALL_TIME_BUDGET = 180  # base image already built; per-project build + run + curl

  setup do
    skip "set E2E_PREVIEW=1 to enable (real docker build/run, ~60-180s)" unless ENV["E2E_PREVIEW"] == "1"

    @workspace_root = Dir.mktmpdir("rails-app-generator-preview-test-")
    @prev_workspace_root = ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"]
    ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] = @workspace_root

    @project = Project.create!(name: "preview_test_#{Time.now.to_i}", user: users(:owner))
    # `fixtures :all` (test_helper.rb) seeds the projects table with hashed
    # huge IDs, which makes Project#preview_port (= 3000 + id) overflow the
    # valid TCP port range. Pick a small free port for the test run.
    test_port = 30000 + rand(20000)
    @project.define_singleton_method(:preview_port) { test_port }
    seed_workspace_from_skeleton(@project.workspace_path)
  end

  teardown do
    Preview::PreviewManager.new.stop(@project) rescue nil if @project
    FileUtils.rm_rf(@workspace_root) if @workspace_root
    if @prev_workspace_root
      ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] = @prev_workspace_root
    else
      ENV.delete("RAILS_APP_GENERATOR_WORKSPACE_ROOT")
    end
  end

  test "full lifecycle: build, run, healthcheck, stop" do
    started = Time.current
    Preview::PreviewManager.new.start(@project)
    elapsed = Time.current - started

    @project.reload
    assert_equal "running", @project.preview_state, "preview_error: #{@project.preview_error}"
    assert @project.preview_container_id.present?
    assert_operator elapsed, :<, WALL_TIME_BUDGET,
      "start took #{elapsed.round}s, exceeds #{WALL_TIME_BUDGET}s budget"

    ok = system("curl", "-fsS", "-o", "/dev/null",
                "http://localhost:#{@project.preview_port}/up")
    assert ok, "preview /up did not respond 2xx"

    Preview::PreviewManager.new.stop(@project)
    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_nil @project.preview_container_id
  end

  private

  # Mirrors ExecuteInstructionJob#init_rails_app minus the master.key write
  # (skeleton boots in development without it) and the `subprocess_env` PATH
  # tweak (parent process is `bundle exec rails test`, so PATH already
  # resolves the pinned Ruby).
  def seed_workspace_from_skeleton(workspace)
    FileUtils.mkdir_p(File.dirname(workspace))
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton')}/.",         workspace)
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton-overlay')}/.", workspace)

    Bundler.with_unbundled_env do
      ok = system("cd #{Shellwords.escape(workspace)} && bundle install --jobs 4 --quiet")
      raise "bundle install failed in test setup" unless ok
      ok = system("cd #{Shellwords.escape(workspace)} && git init -q && git add -A && " \
                  "git -c user.email=t@t -c user.name=t commit -q -m 'seed'")
      raise "git init failed in test setup" unless ok
    end
  end
end
