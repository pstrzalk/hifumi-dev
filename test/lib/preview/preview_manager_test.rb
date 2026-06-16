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

  # --- reset_orphans! (three-category reconciliation) -------------------
  #
  # Containers are managed by the host Docker daemon, not the Rails process.
  # A `kamal deploy` of the generator must NOT kill running user previews.
  # `reset_orphans!` reconciles, it does not nuke. See the comment block
  # above the method definition for the category map.

  test "reset_orphans! Category A: live container with matching DB row is left alone" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", "--format", returns: Result.new(
      ok: true, stdout: "preview-#{@project.id}\n", stderr: "", exit_code: 0
    ))
    runner.script("docker", "ps", "-a", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))
    @project.update!(
      preview_state: :running,
      preview_container_id: "abc",
      preview_started_at: 1.minute.ago
    )

    Preview::PreviewManager.reset_orphans!(runner: runner)

    refute runner.called?("docker", "rm", "-f", "preview-#{@project.id}")
    @project.reload
    assert_equal "running", @project.preview_state
    assert_equal "abc", @project.preview_container_id
  end

  test "reset_orphans! Category B (dev): live container without DB row is killed; no kamal-proxy call when not remote" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", "--format", returns: Result.new(
      ok: true, stdout: "preview-99999\nsome-other-container\n", stderr: "", exit_code: 0
    ))
    runner.script("docker", "ps", "-a", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    Preview::PreviewManager.reset_orphans!(runner: runner)

    assert runner.called?("docker", "rm", "-f", "preview-99999")
    refute runner.called?("docker", "rm", "-f", "some-other-container")
    refute runner.called?("docker", "exec", "kamal-proxy")
  end

  test "reset_orphans! Category B (remote): also runs kamal-proxy remove" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", "--format", returns: Result.new(
      ok: true, stdout: "preview-99999\n", stderr: "", exit_code: 0
    ))
    runner.script("docker", "ps", "-a", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    with_remote do
      Preview::PreviewManager.reset_orphans!(runner: runner)
    end

    assert runner.called?("docker", "rm", "-f", "preview-99999")
    assert runner.called?("docker", "exec", "kamal-proxy", "kamal-proxy", "remove", "preview-99999")
  end

  test "reset_orphans! Category C: DB row with no live container is marked :stopped with marker" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", "--format", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))
    runner.script("docker", "ps", "-a", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))
    @project.update!(
      preview_state: :running,
      preview_container_id: "ghost",
      preview_started_at: 1.minute.ago
    )

    Preview::PreviewManager.reset_orphans!(runner: runner)

    @project.reload
    assert_equal "stopped", @project.preview_state
    assert_match(/Container missing on boot/, @project.preview_error)
    assert_nil @project.preview_container_id
    assert_nil @project.preview_started_at
  end

  test "reset_orphans!: stopped/exited preview-* containers are reaped" do
    runner = FakePreviewRunner.new
    runner.script("docker", "ps", "--format", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))
    runner.script("docker", "ps", "-a", returns: Result.new(
      ok: true, stdout: "preview-77\nsome-other-stopped\n", stderr: "", exit_code: 0
    ))

    Preview::PreviewManager.reset_orphans!(runner: runner)

    assert runner.called?("docker", "rm", "-f", "preview-77")
    refute runner.called?("docker", "rm", "-f", "some-other-stopped")
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

  # --- remote? gating: kamal-proxy register/remove + healthcheck ---------

  test "start (remote): registers kamal-proxy route after healthcheck" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))
    @runner.script("docker", "exec", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    with_remote do
      @manager.start(@project)
    end

    @project.reload
    assert_equal "running", @project.preview_state
    assert @runner.called?("docker", "exec", "kamal-proxy", "kamal-proxy", "deploy", "preview-#{@project.id}")
  end

  test "start (remote): warms the public TLS endpoint after proxy registration and before announcing ready, without -k" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))
    @runner.script("docker", "exec", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    # The whole point of the fix: the cert must be warm before the preview is
    # announced ready. `preview.ready` fires right after the :running flip, so
    # capturing whether the https probe has run by then locks the invariant a
    # future reorder (warm moved below the running flip) would silently break.
    warm_done_before_ready = nil
    sub = ActiveSupport::Notifications.subscribe("preview.ready") do
      warm_done_before_ready =
        @runner.calls.any? { |c| c[:cmd].first == "curl" && c[:cmd].last.start_with?("https://") }
    end

    with_remote do
      @manager.start(@project)
    end

    warm = @runner.calls.find { |c| c[:cmd].first == "curl" && c[:cmd].last.start_with?("https://") }
    assert warm, "start must probe the public https URL so the cert is issued before the user's first visit"
    assert_equal "https://#{@project.id}.preview.hifumi.dev/up", warm[:cmd].last
    refute_includes warm[:cmd], "-k", "the probe must only pass on a browser-trustable cert"

    deploy_idx = @runner.calls.index { |c| c[:cmd].include?("deploy") }
    warm_idx   = @runner.calls.index(warm)
    assert deploy_idx < warm_idx, "the warm probe must run after kamal-proxy registration"

    assert warm_done_before_ready, "the cert must be warmed before the preview is announced ready"
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  test "start (remote): TLS warm timeout is non-fatal — preview still reaches running" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))
    @runner.script("docker", "exec", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))
    # Host-side curl (the TLS probe) never verifies; in-container health
    # checks use the `docker exec` prefix, so they stay green.
    @runner.script("curl", returns: Result.new(ok: false, stdout: "", stderr: "SSL", exit_code: 60))

    manager = Preview::PreviewManager.new(
      runner: @runner,
      health_timeout: 0.05, health_interval: 0.01, tls_warm_timeout: 0.05
    )
    with_remote do
      manager.start(@project)
    end

    assert_equal "running", @project.reload.preview_state,
      "a preview that works must never be failed over the cert warm-up"
  end

  test "start (dev): never probes a public https URL" do
    @manager.start(@project)

    refute @runner.calls.any? { |c| c[:cmd].any? { |a| a.start_with?("https://") } },
      "local previews have no TLS endpoint to warm"
  end

  # --- wildcard (static) cert path --------------------------------------

  test "register (remote, wildcard cert): deploy passes --tls-certificate-path / --tls-private-key-path" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))

    with_remote do
      with_wildcard_tls do
        @manager.start(@project)
      end
    end

    deploy = @runner.calls.find { |c| c[:cmd].include?("deploy") }
    assert deploy, "kamal-proxy deploy was not invoked"
    assert_includes deploy[:cmd], "--tls-certificate-path"
    assert_includes deploy[:cmd], "/proxy/certs/wildcard.crt"
    assert_includes deploy[:cmd], "--tls-private-key-path"
    assert_includes deploy[:cmd], "/proxy/certs/wildcard.key"
  end

  test "start (remote, wildcard cert): skips the public https TLS warm-up (cert already warm)" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))

    with_remote do
      with_wildcard_tls do
        @manager.start(@project)
      end
    end

    refute @runner.calls.any? { |c| c[:cmd].first == "curl" && c[:cmd].last.start_with?("https://") },
      "a pre-issued wildcard cert needs no warm-up — there is no per-host issuance window"
    assert_equal "running", @project.reload.preview_state
  end

  test "register (remote, no wildcard cert): deploy omits the static cert path flags" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))

    with_remote do
      @manager.start(@project)
    end

    deploy = @runner.calls.find { |c| c[:cmd].include?("deploy") }
    assert deploy
    refute_includes deploy[:cmd], "--tls-certificate-path"
    assert_includes deploy[:cmd], "--tls", "on-demand path still passes plain --tls"
  end

  test "start (dev): no kamal-proxy commands invoked" do
    @manager.start(@project)

    refute @runner.called?("docker", "exec", "kamal-proxy")
  end

  test "stop (remote): kamal-proxy remove invoked before docker rm" do
    @project.update!(preview_state: :running, preview_container_id: "abc")

    with_remote do
      @manager.stop(@project)
    end

    proxy_idx = @runner.calls.index { |c| c[:cmd].first(2) == [ "docker", "exec" ] && c[:cmd].include?("kamal-proxy") }
    rm_idx    = @runner.calls.index { |c| c[:cmd].first(3) == [ "docker", "rm", "-f" ] }
    assert proxy_idx, "kamal-proxy remove was not invoked"
    assert rm_idx,    "docker rm was not invoked"
    assert proxy_idx < rm_idx, "kamal-proxy remove must precede docker rm"
  end

  test "ensure_network! (remote): passes --internal flag" do
    with_remote do
      @manager.send(:ensure_network!)
    end

    create_call = @runner.calls.find { |c| c[:cmd].first(3) == [ "docker", "network", "create" ] }
    assert create_call
    assert_includes create_call[:cmd], "--internal"
  end

  test "ensure_network! (dev): omits --internal flag" do
    @manager.send(:ensure_network!)

    create_call = @runner.calls.find { |c| c[:cmd].first(3) == [ "docker", "network", "create" ] }
    assert create_call
    refute_includes create_call[:cmd], "--internal"
  end

  test "run_container (remote): omits host port mapping" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))
    @runner.script("docker", "exec", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    with_remote do
      @manager.start(@project)
    end

    run_call = @runner.calls.find { |c| c[:cmd].first(2) == [ "docker", "run" ] }
    assert run_call
    refute_includes run_call[:cmd], "-p"
  end

  test "run_container (dev): includes -p host port mapping" do
    @manager.start(@project)

    run_call = @runner.calls.find { |c| c[:cmd].first(2) == [ "docker", "run" ] }
    assert run_call
    assert_includes run_call[:cmd], "-p"
    assert_includes run_call[:cmd], "#{@project.preview_port}:3000"
  end

  test "run_container (remote): passes PREVIEW_HOST so the generated app's HostAuthorization allows the kamal-proxy hostname" do
    @runner.script("docker", "inspect", returns: Result.new(
      ok: true, stdout: "172.99.0.5\n", stderr: "", exit_code: 0
    ))
    @runner.script("docker", "exec", returns: Result.new(
      ok: true, stdout: "", stderr: "", exit_code: 0
    ))

    with_remote do
      @manager.start(@project)
    end

    run_call = @runner.calls.find { |c| c[:cmd].first(2) == [ "docker", "run" ] }
    assert run_call
    assert_includes run_call[:cmd], "PREVIEW_HOST=#{@project.id}.preview.hifumi.dev"
  end

  test "run_container (dev): does not set PREVIEW_HOST" do
    @manager.start(@project)

    run_call = @runner.calls.find { |c| c[:cmd].first(2) == [ "docker", "run" ] }
    assert run_call
    refute run_call[:cmd].any? { |a| a.to_s.start_with?("PREVIEW_HOST=") }
  end

  test "curl_ok? (remote): execs curl inside the preview container" do
    with_remote do
      @manager.send(:curl_ok?, @project)
    end

    assert @runner.called?("docker", "exec", "preview-#{@project.id}", "curl")
  end

  test "curl_ok? (dev): runs curl on host against published port" do
    @manager.send(:curl_ok?, @project)

    curl_call = @runner.calls.find { |c| c[:cmd].first == "curl" }
    assert curl_call
    assert_includes curl_call[:cmd].join(" "), "localhost:#{@project.preview_port}/up"
  end

  private

  def with_remote
    original = Rails.configuration.preview.domain
    Rails.configuration.preview.domain = "hifumi.dev"
    yield
  ensure
    Rails.configuration.preview.domain = original
  end

  def with_wildcard_tls
    orig_cert = Rails.configuration.preview.tls_certificate_path
    orig_key  = Rails.configuration.preview.tls_private_key_path
    Rails.configuration.preview.tls_certificate_path = "/proxy/certs/wildcard.crt"
    Rails.configuration.preview.tls_private_key_path = "/proxy/certs/wildcard.key"
    yield
  ensure
    Rails.configuration.preview.tls_certificate_path = orig_cert
    Rails.configuration.preview.tls_private_key_path = orig_key
  end
end
