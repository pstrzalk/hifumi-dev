require "test_helper"

class ExecuteInstructionJobTest < ActiveJob::TestCase
  setup do
    @project = Project.create!(name: "Test Project")
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

  test "skips prepare_workspace + rails_new + init_docs_baseline when workspace already initialized" do
    ws = @project.workspace_path
    FileUtils.mkdir_p(File.join(ws, "docs"))
    File.write(File.join(ws, "Gemfile"), "")

    spy_snapshot = nil
    with_stubs(subprocess: [ [ true, 0, 0.1 ], [ true, 0, 0.1 ] ]) do |spy|
      ExecuteInstructionJob.perform_now(@instruction.id)
      spy_snapshot = spy
    end

    assert_equal 0, spy_snapshot[:prepare_calls]
    assert_equal 0, spy_snapshot[:rails_new_calls]
    assert_equal 0, spy_snapshot[:init_docs_calls]
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
      rails_new_calls: 0,
      init_docs_calls: 0,
      subprocess_calls: [],
      git_head_calls: []
    }

    originals = {
      prepare_workspace:    ExecuteInstructionJob.instance_method(:prepare_workspace),
      rails_new:            ExecuteInstructionJob.instance_method(:rails_new),
      init_docs_baseline:   ExecuteInstructionJob.instance_method(:init_docs_baseline),
      run_roast_subprocess: ExecuteInstructionJob.instance_method(:run_roast_subprocess),
      git_head:             ExecuteInstructionJob.instance_method(:git_head)
    }

    ExecuteInstructionJob.class_eval do
      define_method(:prepare_workspace)   { |_ws| spy[:prepare_calls]   += 1 }
      define_method(:rails_new)           { |_ws| spy[:rails_new_calls] += 1 }
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
