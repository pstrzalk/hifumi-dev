require "test_helper"

class ExecuteInstructionJobTest < ActiveJob::TestCase
  setup do
    @user = create_user(openrouter_api_key: "sk-or-test-fixture-1234567890ab")
    @project = @user.projects.create!(name: "Test Project")
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

  test "skips prepare_workspace + init_rails_app + init_docs_baseline + pick_frontend_template when already initialized" do
    ws = @project.workspace_path
    FileUtils.mkdir_p(File.join(ws, "docs"))
    File.write(File.join(ws, "Gemfile"), "")
    File.write(File.join(ws, "docs/frontend.md"), "# already picked\n")

    spy_snapshot = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      spy_snapshot = spy
    end

    assert_equal 0, spy_snapshot[:prepare_calls]
    assert_equal 0, spy_snapshot[:init_rails_app_calls]
    assert_equal 0, spy_snapshot[:init_docs_calls]
    assert_empty spy_snapshot[:pick_template_calls],
                 "pick_frontend_template must be skipped when docs/frontend.md already exists"
  end

  test "perform invokes pick_frontend_template once when docs/frontend.md is absent" do
    spy_snapshot = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      spy_snapshot = spy
    end

    assert_equal 1, spy_snapshot[:pick_template_calls].size
    call = spy_snapshot[:pick_template_calls].first
    assert_equal @project.workspace_path, call[:workspace]
    assert_equal @instruction, call[:instruction]
  end

  # --- skeleton seed ----------------------------------------------------

  test "init_rails_app seeds workspace from skeleton + overlay (RailsApplication module, executable preview-entrypoint)" do
    Dir.mktmpdir("hifumi-dev-init-test-") do |root|
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

  test "init_rails_app pre-touches log/{development,test}.log so `rails generate` doesn't emit 'Unable to access log file' WARN" do
    Dir.mktmpdir("hifumi-dev-log-touch-") do |root|
      ws = File.join(root, "project_log_touch")
      ExecuteInstructionJob.new.send(:init_rails_app, ws)

      %w[development.log test.log].each do |name|
        path = File.join(ws, "log", name)
        assert File.exist?(path),
               "init_rails_app must create log/#{name} so Rails doesn't WARN-then-create it on first generate"
      end
    end
  end

  test "init_rails_app generates a fresh per-workspace master.key (mode 0600, not in skeleton)" do
    skeleton_root = Rails.root.join("lib/preview/skeleton")
    refute File.exist?(skeleton_root.join("config/master.key")),
           "skeleton must NOT ship a master.key"
    refute File.exist?(skeleton_root.join("config/credentials.yml.enc")),
           "skeleton must NOT ship credentials.yml.enc"

    Dir.mktmpdir("hifumi-dev-key-test-") do |root|
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

  test "skeleton ships .bundle/config with BUNDLE_FROZEN=true so bundle check stops trying to rewrite Gemfile.lock" do
    config_path = Rails.root.join("lib/preview/skeleton/.bundle/config")
    assert File.exist?(config_path), "skeleton must ship .bundle/config"
    assert_match(/BUNDLE_FROZEN:\s*"true"/, File.read(config_path),
                 ".bundle/config must pin BUNDLE_FROZEN=true (eliminates per-revision bundle-version-skew remediation)")
  end

  test "skeleton ships .gitignore so workspace commits don't drag in tmp/log/storage/master.key noise" do
    gitignore_path = Rails.root.join("lib/preview/skeleton/.gitignore")
    assert File.exist?(gitignore_path),
           "skeleton must ship .gitignore — without it every workspace commit pulls in 600+ bootsnap cache files"
    body = File.read(gitignore_path)
    {
      "/log/*"            => "log files (rails generate writes log/development.log every run)",
      "/tmp/*"            => "tmp/cache/bootsnap/** is the dominant noise source per workspace commit",
      "/storage/*"        => "sqlite databases written by bin/rails db:prepare during verify",
      "/config/master.key" => "per-workspace secret, regenerated on init_rails_app — must never enter git"
    }.each do |pattern, why|
      assert_match(/^#{Regexp.escape(pattern)}$/, body,
                   ".gitignore must list `#{pattern}` (#{why})")
    end
  end

  test "init_docs_baseline leaves docs/ world-writable so the agent (running as generator) can edit them" do
    Dir.mktmpdir("hifumi-dev-docs-perm-") do |root|
      ws = File.join(root, "project_docs_perm")
      FileUtils.mkdir_p(ws)
      Dir.chdir(ws) { system("git init -q && git commit -q --allow-empty -m bootstrap") }

      ExecuteInstructionJob.new.send(:init_docs_baseline, ws)

      %w[architecture.md conventions.md domain.md revision_notes.md].each do |name|
        path = File.join(ws, "docs", name)
        mode = File.stat(path).mode & 0o777
        assert_equal 0o666, mode,
                     "#{name} must be world-writable (got #{mode.to_s(8)}) so the generator-side agent can edit it"
      end
    end
  end

  test "relax_workspace_permissions keeps master.key locked at 0600 even though the rest goes world-writable" do
    Dir.mktmpdir("hifumi-dev-relax-perm-") do |root|
      ws = File.join(root, "project_relax_perm")
      FileUtils.mkdir_p(File.join(ws, "config"))
      master_key = File.join(ws, "config/master.key")
      File.write(master_key, "deadbeef" * 4)
      File.write(File.join(ws, "Gemfile.lock"), "GEM\n")
      FileUtils.chmod(0o600, master_key)

      ExecuteInstructionJob.new.send(:relax_workspace_permissions, ws)

      assert_equal 0o600, File.stat(master_key).mode & 0o777, "master.key must stay 0600"
      assert_equal 0o666, File.stat(File.join(ws, "Gemfile.lock")).mode & 0o777,
                   "non-secret files must be world-writable after relax"
    end
  end

  # --- seam shape --------------------------------------------------------

  test "run_roast_subprocess receives HIFUMI_DEV_* env and bin/roast workflow args" do
    first_call = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      first_call = spy[:subprocess_calls].first
    end

    expected_ws = @project.workspace_path
    assert_equal expected_ws, first_call[:env]["HIFUMI_DEV_WORKSPACE"]
    assert_equal ENV.fetch("HIFUMI_DEV_MODEL", "sonnet"),
                 first_call[:env]["HIFUMI_DEV_MODEL"]

    assert_equal Rails.root.join("bin/roast-claudesubscription").to_s, first_call[:args][0]
    assert_equal Rails.root.join("lib/roast/revision_workflow.rb").to_s, first_call[:args][1]
    assert_equal "--",                                                first_call[:args][2]
    assert_equal "revision_id=#{@rev1.id}",                           first_call[:args][3]
    assert_equal "revision_summary=summary 1",                        first_call[:args][4]
    assert_equal "revision_prompt=prompt 1",                          first_call[:args][5]
  end

  test "openrouter path: env carries the project's code and docs model selection" do
    @project.update!(code_model: "anthropic/claude-opus-4.6", docs_model: "anthropic/claude-sonnet-4.6")

    first_call = nil
    with_env("FORCE_OPENROUTER" => "1", "HIFUMI_DEV_MODEL" => nil, "HIFUMI_DEV_DOCS_MODEL" => nil) do
      with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
        ExecuteInstructionJob.perform_now(@instruction.id)
        first_call = spy[:subprocess_calls].first
      end
    end

    assert_equal "anthropic/claude-opus-4.6",   first_call[:env]["HIFUMI_DEV_MODEL"]
    assert_equal "anthropic/claude-sonnet-4.6", first_call[:env]["HIFUMI_DEV_DOCS_MODEL"]
  end

  test "openrouter path: operator HIFUMI_DEV_* env vars override the project selection" do
    @project.update!(code_model: "anthropic/claude-opus-4.6", docs_model: "anthropic/claude-sonnet-4.6")

    first_call = nil
    with_env("FORCE_OPENROUTER" => "1", "HIFUMI_DEV_MODEL" => "pinned-code", "HIFUMI_DEV_DOCS_MODEL" => "pinned-docs") do
      with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
        ExecuteInstructionJob.perform_now(@instruction.id)
        first_call = spy[:subprocess_calls].first
      end
    end

    assert_equal "pinned-code", first_call[:env]["HIFUMI_DEV_MODEL"]
    assert_equal "pinned-docs", first_call[:env]["HIFUMI_DEV_DOCS_MODEL"]
  end

  test "claudesubscription path: project selection is ignored, alias default kept, no docs key" do
    @project.update!(code_model: "anthropic/claude-opus-4.6", docs_model: "anthropic/claude-sonnet-4.6")

    first_call = nil
    with_env("FORCE_OPENROUTER" => nil, "HIFUMI_DEV_MODEL" => nil, "HIFUMI_DEV_DOCS_MODEL" => nil) do
      with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
        ExecuteInstructionJob.perform_now(@instruction.id)
        first_call = spy[:subprocess_calls].first
      end
    end

    assert_equal "sonnet", first_call[:env]["HIFUMI_DEV_MODEL"]
    assert_not first_call[:env].key?("HIFUMI_DEV_DOCS_MODEL"),
      "claudesubscription path must leave docs model to the workflow's alias default"
  end

  test "run_roast_subprocess env forces RAILS_ENV=development for workspace rails commands" do
    first_call = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      first_call = spy[:subprocess_calls].first
    end

    assert_equal "development", first_call[:env]["RAILS_ENV"],
                 "the generator container is RAILS_ENV=production, but the workspace must boot in development"
  end

  test "run_roast_subprocess env carries the project owner's openrouter key" do
    first_call = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      first_call = spy[:subprocess_calls].first
    end

    assert_equal "sk-or-test-fixture-1234567890ab",
                 first_call[:env]["OPENROUTER_API_KEY"]
  end

  test "raises when project owner has no openrouter key (subprocess never invoked)" do
    @user.profile.update_columns(openrouter_api_key: nil)
    with_stubs(subprocess: [ [ true, 0, 0.1 ] ]) do |spy|
      assert_raises(RuntimeError) { ExecuteInstructionJob.perform_now(@instruction.id) }
      assert_empty spy[:subprocess_calls],
        "subprocess must NOT be invoked when the owner has no API key"
    end
    assert_equal "pending", @rev2.reload.status
  end

  # --- pick_frontend_template -------------------------------------------

  test "pick_frontend_template threads instruction.user_intent as description and project owner's key" do
    @instruction.update!(user_intent: "neon hacker dashboard for tracking exploits")
    ws = @project.workspace_path
    FileUtils.mkdir_p(ws)

    picker_calls = nil
    with_picker_call_stub do |calls|
      ExecuteInstructionJob.new.send(:pick_frontend_template, ws, @instruction)
      picker_calls = calls
    end

    assert_equal 1, picker_calls.size
    call = picker_calls.first
    assert_equal ws, call[:workspace]
    assert_equal "neon hacker dashboard for tracking exploits", call[:description]
    assert_equal "sk-or-test-fixture-1234567890ab", call[:openrouter_api_key]
  end

  test "pick_frontend_template threads the project's template model selection" do
    @project.update!(template_model: "anthropic/claude-opus-4.6")
    ws = @project.workspace_path
    FileUtils.mkdir_p(ws)

    picker_calls = nil
    with_picker_call_stub do |calls|
      ExecuteInstructionJob.new.send(:pick_frontend_template, ws, @instruction)
      picker_calls = calls
    end

    assert_equal "anthropic/claude-opus-4.6", picker_calls.first[:model]
  end

  test "pick_frontend_template falls back to project.name when instruction.user_intent is blank" do
    @instruction.update!(user_intent: "")
    ws = @project.workspace_path
    FileUtils.mkdir_p(ws)

    picker_calls = nil
    with_picker_call_stub do |calls|
      ExecuteInstructionJob.new.send(:pick_frontend_template, ws, @instruction)
      picker_calls = calls
    end

    assert_equal @project.name, picker_calls.first[:description]
  end

  test "pick_frontend_template raises when project owner has no OpenRouter API key" do
    @user.profile.update_columns(openrouter_api_key: nil)
    err = assert_raises(RuntimeError) do
      ExecuteInstructionJob.new.send(:pick_frontend_template, @project.workspace_path, @instruction)
    end
    assert_match(/no OpenRouter API key/i, err.message)
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

  # --- roast wrapper selection ------------------------------------------

  test "roast_executable is bin/roast-claudesubscription in dev (no FORCE_OPENROUTER)" do
    original = ENV.delete("FORCE_OPENROUTER")
    assert_equal Rails.root.join("bin/roast-claudesubscription").to_s,
                 ExecuteInstructionJob.new.send(:roast_executable)
  ensure
    ENV["FORCE_OPENROUTER"] = original if original
  end

  test "roast_executable is bin/roast-openrouter in production" do
    original_force = ENV.delete("FORCE_OPENROUTER")
    original_env = Rails.env
    Rails.env = "production"
    assert_equal Rails.root.join("bin/roast-openrouter").to_s,
                 ExecuteInstructionJob.new.send(:roast_executable)
  ensure
    Rails.env = original_env if original_env
    ENV["FORCE_OPENROUTER"] = original_force if original_force
  end

  test "roast_executable is bin/roast-openrouter when FORCE_OPENROUTER is set in dev" do
    original = ENV["FORCE_OPENROUTER"]
    ENV["FORCE_OPENROUTER"] = "1"
    assert_equal Rails.root.join("bin/roast-openrouter").to_s,
                 ExecuteInstructionJob.new.send(:roast_executable)
  ensure
    ENV["FORCE_OPENROUTER"] = original
  end

  # --- per-instruction container isolation ------------------------------

  test "sandboxed? is false in dev/test (single-tenant, no container)" do
    assert_not ExecuteInstructionJob.new.send(:sandboxed?)
  end

  test "sandboxed? is true in production" do
    original_env = Rails.env
    Rails.env = "production"
    assert ExecuteInstructionJob.new.send(:sandboxed?)
  ensure
    Rails.env = original_env if original_env
  end

  test "sandboxed? is true when FORCE_AGENT_SANDBOX is set in dev" do
    with_env("FORCE_AGENT_SANDBOX" => "1") do
      assert ExecuteInstructionJob.new.send(:sandboxed?)
    end
  end

  test "sandboxing forces the OpenRouter transport (image has no host OAuth creds)" do
    with_env("FORCE_AGENT_SANDBOX" => "1") do
      assert_equal Rails.root.join("bin/roast-openrouter").to_s,
                   ExecuteInstructionJob.new.send(:roast_executable)
    end
  end

  test "revision_command returns the bare roast invocation when not sandboxed" do
    args = ExecuteInstructionJob.new.send(:revision_command, @rev1, @project.workspace_path, {})
    assert_equal Rails.root.join("bin/roast-claudesubscription").to_s, args[0]
    assert_equal Rails.root.join("lib/roast/revision_workflow.rb").to_s, args[1]
  end

  test "revision_command wraps the roast invocation in a docker run when sandboxed" do
    with_env("FORCE_AGENT_SANDBOX" => "1", "HIFUMI_AGENT_IMAGE" => "registry/hifumi-dev:latest") do
      env = { "OPENROUTER_API_KEY" => "sk-or-secret", "HIFUMI_DEV_WORKSPACE" => @project.workspace_path }
      args = ExecuteInstructionJob.new.send(:revision_command, @rev1, @project.workspace_path, env)

      assert_equal %w[docker run --rm], args.first(3)
      # the workspace is the only mount, the socket is never mounted
      mounts = args.each_cons(2).select { |flag, _| flag == "-v" }.map(&:last)
      assert_equal [ "#{@project.workspace_path}:#{@project.workspace_path}" ], mounts
      assert_not args.any? { |a| a.include?("docker.sock") }
      # the wrapped command (openrouter wrapper) sits after the image
      image_idx = args.index("registry/hifumi-dev:latest")
      assert_equal Rails.root.join("bin/roast-openrouter").to_s, args[image_idx + 1]
      # the secret is forwarded by name, never as a value in argv
      assert_includes args.each_cons(2).select { |f, _| f == "-e" }.map(&:last), "OPENROUTER_API_KEY"
      assert_not args.any? { |a| a.include?("sk-or-secret") }
    end
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
      pick_template_calls: [],
      subprocess_calls: [],
      git_head_calls: []
    }

    originals = {
      prepare_workspace:      ExecuteInstructionJob.instance_method(:prepare_workspace),
      init_rails_app:         ExecuteInstructionJob.instance_method(:init_rails_app),
      init_docs_baseline:     ExecuteInstructionJob.instance_method(:init_docs_baseline),
      pick_frontend_template: ExecuteInstructionJob.instance_method(:pick_frontend_template),
      run_roast_subprocess:   ExecuteInstructionJob.instance_method(:run_roast_subprocess),
      git_head:               ExecuteInstructionJob.instance_method(:git_head)
    }

    ExecuteInstructionJob.class_eval do
      define_method(:prepare_workspace)      { |_ws| spy[:prepare_calls]   += 1 }
      define_method(:init_rails_app)         { |_ws| spy[:init_rails_app_calls] += 1 }
      define_method(:init_docs_baseline)     { |_ws| spy[:init_docs_calls] += 1 }
      define_method(:pick_frontend_template) { |ws, instr| spy[:pick_template_calls] << { workspace: ws, instruction: instr } }
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

  # Replace Templates::Picker.call with a recorder for the duration of the
  # block. Returns the canonical "cyber" name so callers that expect a
  # Templates::NAMES-valid result keep working. Mirrors the singleton-method-
  # swap pattern used in test/lib/verify_revision_test.rb (Minitest 6 dropped
  # Object#stub).
  def with_picker_call_stub(return_value: "cyber")
    calls = []
    Templates::Picker.singleton_class.alias_method(:__orig_call, :call)
    Templates::Picker.define_singleton_method(:call) do |**args|
      calls << args
      return_value
    end
    yield calls
  ensure
    Templates::Picker.singleton_class.alias_method(:call, :__orig_call)
    Templates::Picker.singleton_class.send(:remove_method, :__orig_call)
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
