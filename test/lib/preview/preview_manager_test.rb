require "test_helper"

# Fake runner that records every call and returns scripted Result objects.
# Mirrors the injectable-runner pattern from ExecuteInstructionJob#run_roast_subprocess.
class FakePreviewRunner
  Result = Preview::PreviewManager::Result

  attr_reader :calls

  def initialize
    @calls   = []
    @scripts = {} # prefix (Array<String>) => Result. Most-specific prefix wins.
    @default_result = Result.new(ok: true, stdout: "", stderr: "", exit_code: 0)
  end

  # Sets the result returned for any call whose argv starts with `prefix`.
  # Re-scripting the same prefix REPLACES the previous result — setup defines
  # baselines, tests override specific commands. Most-specific prefix (longest
  # match) wins so e.g. ("docker", "rm") and ("docker", "rm", "-f", "X") can
  # coexist without ambiguity.
  def script(*prefix, returns:)
    @scripts[prefix.map(&:to_s)] = returns
  end

  def run(*cmd, capture: false, timeout: nil)
    cmd = cmd.flatten.map(&:to_s)
    @calls << { cmd: cmd, capture: capture, timeout: timeout }

    match = @scripts.keys
                    .select { |prefix| cmd.first(prefix.size) == prefix }
                    .max_by(&:size)
    match ? @scripts[match] : @default_result
  end

  def called?(*prefix)
    prefix = prefix.map(&:to_s)
    @calls.any? { |c| c[:cmd].first(prefix.size) == prefix }
  end

  def call_count(*prefix)
    prefix = prefix.map(&:to_s)
    @calls.count { |c| c[:cmd].first(prefix.size) == prefix }
  end
end

class Preview::PreviewManagerTest < ActiveSupport::TestCase
  Result = Preview::PreviewManager::Result

  setup do
    @project = Project.create!(name: "PreviewTest", user: users(:owner))
    @runner  = FakePreviewRunner.new
    @manager = Preview::PreviewManager.new(
      runner: @runner,
      health_timeout: 0.05,
      health_interval: 0.01
    )

    # Default success scripts. Tests override individual ones.
    @runner.script("docker", "network", "inspect", returns: Result.new(ok: false, stdout: "", stderr: "", exit_code: 1))
    @runner.script("docker", "network", "create",  returns: Result.new(ok: true,  stdout: "", stderr: "", exit_code: 0))
    @runner.script("docker", "build",              returns: Result.new(ok: true,  stdout: "", stderr: "", exit_code: 0))
    @runner.script("docker", "run",                returns: Result.new(ok: true,  stdout: "container_abc123\n", stderr: "", exit_code: 0))
    @runner.script("curl",                         returns: Result.new(ok: true,  stdout: "", stderr: "", exit_code: 0))
  end

  # --- happy path -------------------------------------------------------

  test "start: stopped → starting → running, container_id set, preview.ready instrumented" do
    payload = nil
    sub = ActiveSupport::Notifications.subscribe("preview.ready") { |*, p| payload = p }

    @manager.start(@project)

    @project.reload
    assert_equal "running", @project.preview_state
    assert_equal "container_abc123", @project.preview_container_id
    assert_not_nil @project.preview_started_at
    assert_nil @project.preview_error

    assert_equal @project.id, payload[:project_id]
    assert_equal "http://localhost:#{3000 + @project.id}", payload[:url]
    assert @runner.called?("docker", "build")
    assert @runner.called?("docker", "run")
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  # --- build failure ----------------------------------------------------

  test "start: build failure → state=failed, error stored, image cleanup attempted" do
    @runner.script("docker", "build", returns: Result.new(ok: false, stdout: "", stderr: "boom: bundle install failed", exit_code: 1))

    @manager.start(@project)

    @project.reload
    assert_equal "failed", @project.preview_state
    assert_match(/boom: bundle install failed/, @project.preview_error)
    assert_nil @project.preview_container_id
    # No container_id was set, so no `docker rm -f` for it. But image cleanup ran.
    assert @runner.called?("docker", "image", "rm")
  end

  # --- run failure ------------------------------------------------------

  test "start: docker run failure → state=failed, image cleanup attempted" do
    @runner.script("docker", "run", returns: Result.new(ok: false, stdout: "", stderr: "name already in use", exit_code: 125))

    @manager.start(@project)

    @project.reload
    assert_equal "failed", @project.preview_state
    assert_match(/name already in use/, @project.preview_error)
    assert @runner.called?("docker", "image", "rm")
  end

  # --- healthcheck timeout ----------------------------------------------

  test "start: healthcheck timeout → state=failed, container removed" do
    @runner.script("curl", returns: Result.new(ok: false, stdout: "", stderr: "", exit_code: 7))

    # health_timeout/interval injected as 0.05s/0.01s in setup, so this loops
    # ~5 times and raises in real time.
    @manager.start(@project)

    @project.reload
    assert_equal "failed", @project.preview_state
    assert_match(/no \/up after/, @project.preview_error)
    # Container existed (run succeeded) — must be force-removed.
    assert @runner.called?("docker", "rm", "-f", "container_abc123")
  end

  # --- idempotent start -------------------------------------------------

  test "start: with existing container_id, stops first then restarts" do
    @project.update!(preview_container_id: "old_container_xyz", preview_state: :running)

    @manager.start(@project)

    # Stop must have removed the old container.
    assert @runner.called?("docker", "rm", "-f", "old_container_xyz")
    @project.reload
    assert_equal "running", @project.preview_state
    assert_equal "container_abc123", @project.preview_container_id
  end

  # --- stop -------------------------------------------------------------

  test "stop: with no container_id is a no-op except state reset" do
    @project.update!(preview_state: :failed, preview_error: "stale")

    @manager.stop(@project)

    refute @runner.called?("docker", "rm")
    refute @runner.called?("docker", "image", "rm")
    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_nil @project.preview_error
  end

  test "stop: removes container + image, clears columns" do
    @project.update!(
      preview_state: :running,
      preview_container_id: "ghost_container",
      preview_started_at: 5.minutes.ago
    )

    @manager.stop(@project)

    assert @runner.called?("docker", "rm", "-f", "ghost_container")
    assert @runner.called?("docker", "image", "rm")
    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_nil @project.preview_container_id
    assert_nil @project.preview_started_at
    assert_nil @project.preview_error
  end

  # --- ensure_network! --------------------------------------------------

  test "ensure_network!: skips creation when network already exists" do
    @runner.script("docker", "network", "inspect", returns: Result.new(ok: true, stdout: "", stderr: "", exit_code: 0))

    @manager.send(:ensure_network!)

    assert_equal 0, @runner.call_count("docker", "network", "create")
  end

  test "ensure_network!: creates network when inspect fails (idempotent re-call)" do
    # Default setup: inspect returns false. So create must run.
    @manager.send(:ensure_network!)
    assert_equal 1, @runner.call_count("docker", "network", "create")
  end

  # --- reset_orphans! ---------------------------------------------------

  test "reset_orphans!: kills preview-* containers + flips DB rows to :stopped with marker" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", returns: Result.new(
      ok: true,
      stdout: "preview-#{@project.id}\nsome-other-container\npreview-99\n",
      stderr: "",
      exit_code: 0
    ))
    @project.update!(
      preview_state: :running,
      preview_container_id: "abc",
      preview_started_at: 1.minute.ago
    )

    Preview::PreviewManager.reset_orphans!(runner: runner)

    # Both preview-* containers were rm'd; the unrelated container was not.
    assert runner.called?("docker", "rm", "-f", "preview-#{@project.id}")
    assert runner.called?("docker", "rm", "-f", "preview-99")
    refute runner.called?("docker", "rm", "-f", "some-other-container")

    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_match(/Reset on boot/, @project.preview_error)
    assert_nil @project.preview_container_id
    assert_nil @project.preview_started_at
  end

  test "reset_orphans!: when docker is unavailable, rescues + logs (does NOT raise)" do
    runner = Object.new
    def runner.run(*)
      raise Errno::ENOENT, "No such file or directory - docker"
    end

    assert_nothing_raised do
      Preview::PreviewManager.reset_orphans!(runner: runner)
    end
  end
end
