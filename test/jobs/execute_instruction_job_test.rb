require "test_helper"

class ExecuteInstructionJobTest < ActiveJob::TestCase
  setup do
    @project = Project.create!(name: "Test Project", user: users(:owner))
    @chat = @project.create_chat!
    @msg = @chat.messages.create!(role: :user, content: "hi")
    @instruction = @project.instructions.create!(
      anchor_message: @msg,
      description: "A simple instruction.",
      user_intent: "test",
      phase: :implementing
    )
    @rev1 = build_rev(0, "summary 1", "prompt 1")
    @rev2 = build_rev(1, "summary 2", "prompt 2", parent: @rev1)
  end

  teardown do
    FileUtils.rm_rf(@project.workspace_path) if @project
  end

  # --- happy path --------------------------------------------------------

  test "happy path: both revisions succeed, statuses transition, 5 notifications emitted in order" do
    events = nil
    with_stubs(subprocess: [ [ true, 0, 1.2 ], [ true, 0, 1.5 ] ], git_shas: [ "sha_one", "sha_two" ]) do
      events = capture_all_events do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end
    end

    assert_equal "completed", @rev1.reload.status
    assert_equal "completed", @rev2.reload.status
    assert_equal "sha_one", @rev1.git_sha
    assert_equal "sha_two", @rev2.git_sha
    assert_equal 1.2, @rev1.metrics["wall_seconds"]
    assert_equal 0,   @rev1.metrics["exit_code"]
    assert_equal "sha_one", @rev1.metrics["git_sha"]
    assert_equal "completed", @instruction.reload.phase

    assert_equal(
      [ "revision.started", "revision.completed",
        "revision.started", "revision.completed",
        "instruction.completed" ],
      events.map(&:first)
    )
  end

  # --- failure paths -----------------------------------------------------

  test "first revision failure breaks the loop and marks instruction failed" do
    events = nil
    subprocess_calls = nil
    with_stubs(subprocess: [ [ false, 1, 0.5 ] ]) do |spy|
      events = capture_all_events do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end
      subprocess_calls = spy[:subprocess_calls].size
    end

    assert_equal 1, subprocess_calls, "second revision must not invoke the subprocess after the first fails"
    assert_equal "failed",  @rev1.reload.status
    assert_equal "pending", @rev2.reload.status
    assert_equal "failed",  @instruction.reload.phase

    assert_equal [ "revision.started", "revision.failed", "instruction.failed" ], events.map(&:first)
  end

  test "second revision failure after first completes still marks instruction failed" do
    events = nil
    with_stubs(subprocess: [ [ true, 0, 1.0 ], [ false, 2, 0.3 ] ], git_shas: [ "sha_first", "" ]) do
      events = capture_all_events do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end
    end

    assert_equal "completed", @rev1.reload.status
    assert_equal "failed",    @rev2.reload.status
    assert_equal "failed",    @instruction.reload.phase

    assert_equal(
      [ "revision.started", "revision.completed",
        "revision.started", "revision.failed",
        "instruction.failed" ],
      events.map(&:first)
    )
  end

  # --- idempotent setup --------------------------------------------------

  test "skips prepare_workspace + init_rails_app + init_docs_baseline when workspace already initialized" do
    ws = @project.workspace_path
    FileUtils.mkdir_p(File.join(ws, "docs"))
    File.write(File.join(ws, "Gemfile"), "")

    spy_snapshot = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      spy_snapshot = spy
    end

    assert_equal 0, spy_snapshot[:prepare_calls]
    assert_equal 0, spy_snapshot[:init_rails_app_calls]
    assert_equal 0, spy_snapshot[:init_docs_calls]
  end

  # --- skeleton seed ----------------------------------------------------

  test "init_rails_app seeds workspace from skeleton + overlay (RailsApplication module, executable preview-entrypoint)" do
    Dir.mktmpdir("rails-app-generator-init-test-") do |root|
      ws = File.join(root, "project_test")
      ExecuteInstructionJob.new.send(:init_rails_app, ws)

      app_rb = File.read(File.join(ws, "config", "application.rb"))
      assert_match(/module RailsApplication\b/, app_rb,
                   "skeleton must define module RailsApplication")

      entrypoint = File.join(ws, "bin", "preview-entrypoint")
      assert File.exist?(entrypoint),    "skeleton-overlay must drop bin/preview-entrypoint"
      assert File.executable?(entrypoint), "bin/preview-entrypoint must be executable"
    end
  end

  test "init_rails_app generates a fresh per-workspace master.key (mode 0600, not in skeleton)" do
    skeleton_root = Rails.root.join("lib/preview/skeleton")
    refute File.exist?(skeleton_root.join("config/master.key")),
           "skeleton must NOT ship a master.key"
    refute File.exist?(skeleton_root.join("config/credentials.yml.enc")),
           "skeleton must NOT ship credentials.yml.enc"

    Dir.mktmpdir("rails-app-generator-key-test-") do |root|
      ws_a = File.join(root, "project_a")
      ws_b = File.join(root, "project_b")
      ExecuteInstructionJob.new.send(:init_rails_app, ws_a)
      ExecuteInstructionJob.new.send(:init_rails_app, ws_b)

      key_a_path = File.join(ws_a, "config/master.key")
      key_b_path = File.join(ws_b, "config/master.key")
      assert File.exist?(key_a_path), "master.key must be generated per workspace"
      assert File.exist?(key_b_path)

      key_a = File.read(key_a_path)
      key_b = File.read(key_b_path)
      assert_match(/\A[0-9a-f]{32}\z/, key_a, "master.key must be 32-char hex")
      refute_equal key_a, key_b, "each workspace must get a unique master.key"

      # 0600 — owner read/write only.
      assert_equal 0o600, File.stat(key_a_path).mode & 0o777
    end
  end

  # --- seam shape --------------------------------------------------------

  test "run_roast_subprocess receives RAILS_APP_GENERATOR_* env and bin/roast workflow args" do
    first_call = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      first_call = spy[:subprocess_calls].first
    end

    expected_ws = @project.workspace_path
    assert_equal expected_ws, first_call[:env]["RAILS_APP_GENERATOR_WORKSPACE"]
    assert_equal ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet"),
                 first_call[:env]["RAILS_APP_GENERATOR_MODEL"]

    assert_equal Rails.root.join("bin/roast").to_s,                   first_call[:args][0]
    assert_equal Rails.root.join("lib/roast/revision_workflow.rb").to_s, first_call[:args][1]
    assert_equal "--",                                                first_call[:args][2]
    assert_equal "revision_id=#{@rev1.id}",                           first_call[:args][3]
    assert_equal "revision_summary=summary 1",                        first_call[:args][4]
    assert_equal "revision_prompt=prompt 1",                          first_call[:args][5]
  end

  # --- subprocess_env normalization -------------------------------------

  test "subprocess_env strips the ruby- prefix from .ruby-version when computing frum_bin" do
    raw = File.read(Rails.root.join(".ruby-version")).strip
    expected_version = raw.delete_prefix("ruby-")
    expected_bin = File.join(Dir.home, ".frum", "versions", expected_version, "bin")
    skip "frum bin for #{expected_version} is not installed at #{expected_bin}" unless File.directory?(expected_bin)

    env = ExecuteInstructionJob.new.send(:subprocess_env)
    assert_equal "#{expected_bin}:#{ENV.fetch('PATH', '')}", env["PATH"]
  end

  # --- notification payload shapes --------------------------------------

  test "revision.completed payload is {revision_id:, git_sha:}" do
    payload = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ], git_shas: [ "abc123", "def456" ]) do
      payload = capture_events("revision.completed") do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end.first.last
    end

    assert_equal({ revision_id: @rev1.id, git_sha: "abc123" }, payload)
  end

  test "revision.failed payload is {revision_id:, error: 'exit N'}" do
    payload = nil
    with_stubs(subprocess: [ [ false, 42, 0.1 ] ]) do
      payload = capture_events("revision.failed") do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end.first.last
    end

    assert_equal({ revision_id: @rev1.id, error: "exit 42" }, payload)
  end

  test "instruction.completed/failed payload is {instruction_id:}" do
    completed_payload = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do
      completed_payload = capture_events("instruction.completed") do
        ExecuteInstructionJob.perform_now(@instruction.id)
      end.first.last
    end
    assert_equal({ instruction_id: @instruction.id }, completed_payload)

    # Reset for the failure arm: new instruction so the first run's state doesn't interfere.
    other_instruction = @project.instructions.create!(
      anchor_message: @msg, description: "Other", user_intent: "x", phase: :implementing
    )
    other_instruction.revisions.create!(
      project: @project, position: 0, status: :pending, summary: "s", prompt: "p"
    )

    failed_payload = nil
    with_stubs(subprocess: [ [ false, 1, 0.1 ] ]) do
      failed_payload = capture_events("instruction.failed") do
        ExecuteInstructionJob.perform_now(other_instruction.id)
      end.first.last
    end
    assert_equal({ instruction_id: other_instruction.id }, failed_payload)
  end

  # --- subscriber wiring (initializer-driven) ---------------------------

  test "instruction.requested notification enqueues ExecuteInstructionJob on the generation queue" do
    assert_enqueued_with(
      job: ExecuteInstructionJob,
      args: [ @instruction.id ],
      queue: "generation"
    ) do
      ActiveSupport::Notifications.instrument("instruction.requested", instruction_id: @instruction.id)
    end
  end

  private

  def build_rev(position, summary, prompt, parent: nil)
    @instruction.revisions.create!(
      project: @project,
      position: position,
      status: :pending,
      summary: summary,
      prompt: prompt,
      parent: parent
    )
  end

  # Stubs all side-effectful helpers on ExecuteInstructionJob.
  # - `subprocess:` Array of [ok, exit_code, wall_seconds] tuples, one per call.
  #   Defaults to [true, 0, 0.1] if exhausted.
  # - `git_shas:` Array of sha strings, one per git_head call. Defaults to "".
  # Yields a spy Hash for call-count / argument assertions.
  def with_stubs(subprocess: [], git_shas: [])
    subprocess = subprocess.dup
    git_shas = git_shas.dup
    spy = {
      prepare_calls: 0,
      init_rails_app_calls: 0,
      init_docs_calls: 0,
      subprocess_calls: [],
      git_head_calls: []
    }

    originals = {
      prepare_workspace:    ExecuteInstructionJob.instance_method(:prepare_workspace),
      init_rails_app:       ExecuteInstructionJob.instance_method(:init_rails_app),
      init_docs_baseline:   ExecuteInstructionJob.instance_method(:init_docs_baseline),
      run_roast_subprocess: ExecuteInstructionJob.instance_method(:run_roast_subprocess),
      git_head:             ExecuteInstructionJob.instance_method(:git_head)
    }

    ExecuteInstructionJob.class_eval do
      define_method(:prepare_workspace)   { |_ws| spy[:prepare_calls]   += 1 }
      define_method(:init_rails_app)      { |_ws| spy[:init_rails_app_calls] += 1 }
      define_method(:init_docs_baseline)  { |_ws| spy[:init_docs_calls] += 1 }
      define_method(:run_roast_subprocess) do |env, args|
        spy[:subprocess_calls] << { env: env, args: args }
        subprocess.shift || [ true, 0, 0.1 ]
      end
      define_method(:git_head) do |ws|
        spy[:git_head_calls] << ws
        git_shas.shift || ""
      end
    end

    yield spy
  ensure
    originals&.each do |m, original|
      ExecuteInstructionJob.class_eval { define_method(m, original) }
    end
  end

  def capture_all_events
    capture_events(
      "revision.started", "revision.completed", "revision.failed",
      "instruction.completed", "instruction.failed"
    ) { yield }
  end

  def capture_events(*names)
    events = []
    subs = names.map do |name|
      ActiveSupport::Notifications.subscribe(name) do |n, *, payload|
        events << [ n, payload ]
      end
    end
    yield
    events
  ensure
    subs&.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
  end
end
