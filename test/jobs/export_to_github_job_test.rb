require "test_helper"
require "ostruct"

class ExportToGithubJobTest < ActiveJob::TestCase
  setup do
    @user = create_user
    @project = @user.projects.create!(name: "Exportable Project")
    @user.create_github_connection!(
      provider: "github_oauth",
      github_username: "octocat",
      github_user_id: 1,
      access_token: "gho_test_token"
    )
    # Pretend the workspace exists. workspace_initialized? checks for Gemfile.
    FileUtils.mkdir_p(@project.workspace_path)
    File.write(File.join(@project.workspace_path, "Gemfile"), "source 'https://rubygems.org'\n")
  end

  teardown do
    FileUtils.rm_rf(@project.workspace_path) if @project
  end

  # --- happy path: first export -----------------------------------------

  test "first export creates repo via Octokit, pushes, and persists state" do
    repo_response = OpenStruct.new(full_name: "octocat/exportable-project")
    octokit_calls = []
    system_calls  = []
    open3_calls   = []

    with_octokit_stub(repo_response, octokit_calls) do
      with_system_stub(system_calls) do
        with_open3_stub(open3_calls, success: true) do
          ExportToGithubJob.perform_now(@project.id, repo_name: "exportable-project", private_repo: true)
        end
      end
    end

    @project.reload
    assert_equal "octocat/exportable-project", @project.github_repo_full_name
    assert_equal "exported", @project.export_state
    assert_not_nil @project.exported_at
    assert_nil @project.export_error

    # Octokit was called exactly once with the right args.
    assert_equal 1, octokit_calls.size
    assert_equal "exportable-project", octokit_calls.first[:name]
    assert_equal({ private: true, auto_init: false }, octokit_calls.first[:options])

    # `git remote add origin` happened with the CLEAN URL (no token).
    assert(system_calls.any? { |c| c.include?("git remote add origin") },
           "must call git remote add origin")
    add_origin = system_calls.find { |c| c.include?("git remote add origin") }
    refute_match(/gho_test_token/, add_origin,
                 "token must NEVER appear in the stored remote URL")
    refute_match(/x-access-token/, add_origin,
                 "token-bearing URL pattern must NEVER reach git remote add")
    assert_match(%r{https://github\.com/octocat/exportable-project\.git}, add_origin)

    # The push received the token-bearing URL via Open3 argv (not via remote).
    assert_equal 1, open3_calls.size
    assert_includes open3_calls.first[:args], "https://x-access-token:gho_test_token@github.com/octocat/exportable-project.git"
    assert_includes open3_calls.first[:args], "main"
  end

  # --- happy path: subsequent push --------------------------------------

  test "subsequent export skips Octokit when github_repo_full_name is already set" do
    @project.update!(github_repo_full_name: "octocat/exportable-project")

    octokit_calls = []
    system_calls  = []
    open3_calls   = []

    with_octokit_stub(nil, octokit_calls) do
      with_system_stub(system_calls) do
        with_open3_stub(open3_calls, success: true) do
          ExportToGithubJob.perform_now(@project.id)
        end
      end
    end

    assert_equal 0, octokit_calls.size,
                 "must not call create_repository when github_repo_full_name is already set"
    assert_equal "exported", @project.reload.export_state
    assert_equal 1, open3_calls.size, "still pushed once"
  end

  # --- failure: token revoked ------------------------------------------

  test "Octokit::Unauthorized from create_repository → state failed, raises TokenRevoked" do
    err = assert_raises(ExportToGithubJob::TokenRevoked) do
      with_octokit_stub(nil, [], raise_with: Octokit::Unauthorized) do
        ExportToGithubJob.perform_now(@project.id, repo_name: "x")
      end
    end
    assert_match(/reconnect/i, err.message)
    @project.reload
    assert_equal "failed", @project.export_state
    assert_match(/reconnect/i, @project.export_error)
  end

  # --- failure: 422 from create ----------------------------------------

  test "Octokit::UnprocessableEntity 'name already exists' → state failed, friendly name-collision message" do
    err = assert_raises(ExportToGithubJob::RepoCreateFailed) do
      with_octokit_stub(nil, [], raise_with: Octokit::UnprocessableEntity.new(body: { errors: [ { message: "name already exists on this account" } ] })) do
        ExportToGithubJob.perform_now(@project.id, repo_name: "x")
      end
    end
    assert_match(/repository with that name already exists/i, err.message)
    refute_match(/POST https|422 -/, err.message, "must not leak Octokit's raw HTTP error format")
    @project.reload
    assert_equal "failed", @project.export_state
    assert_match(/repository with that name already exists/i, @project.export_error)
  end

  test "Octokit::UnprocessableEntity for other 422 causes → state failed, generic message" do
    err = assert_raises(ExportToGithubJob::RepoCreateFailed) do
      with_octokit_stub(nil, [], raise_with: Octokit::UnprocessableEntity.new(body: { errors: [ { message: "name contains invalid characters" } ] })) do
        ExportToGithubJob.perform_now(@project.id, repo_name: "x")
      end
    end
    assert_match(/rejected the repository creation request/i, err.message)
    @project.reload
    assert_equal "failed", @project.export_state
  end

  # --- failure: push diverged ------------------------------------------

  test "push diverged → state failed, raises PushDiverged, no force" do
    repo_response = OpenStruct.new(full_name: "octocat/exportable-project")

    err = assert_raises(ExportToGithubJob::PushDiverged) do
      with_octokit_stub(repo_response, []) do
        with_system_stub([]) do
          with_open3_stub([], success: false, stderr: "! [rejected] main -> main (non-fast-forward)") do
            ExportToGithubJob.perform_now(@project.id, repo_name: "x")
          end
        end
      end
    end
    assert_match(/can't push.*commits this app doesn't know/i, err.message)
    @project.reload
    assert_equal "failed", @project.export_state
  end

  # --- failure: push reports bad credentials ---------------------------

  test "push with bad credentials → state failed, raises TokenRevoked" do
    repo_response = OpenStruct.new(full_name: "octocat/exportable-project")

    err = assert_raises(ExportToGithubJob::TokenRevoked) do
      with_octokit_stub(repo_response, []) do
        with_system_stub([]) do
          with_open3_stub([], success: false, stderr: "fatal: Authentication failed for ...") do
            ExportToGithubJob.perform_now(@project.id, repo_name: "x")
          end
        end
      end
    end
    assert_match(/reconnect/i, err.message)
    @project.reload
    assert_equal "failed", @project.export_state
  end

  # --- workspace missing -----------------------------------------------

  test "raises WorkspaceMissing when Gemfile is absent" do
    File.delete(File.join(@project.workspace_path, "Gemfile"))
    assert_raises(ExportToGithubJob::WorkspaceMissing) do
      ExportToGithubJob.perform_now(@project.id)
    end
  end

  # --- no github connection --------------------------------------------

  test "raises TokenRevoked when user has no github_connection" do
    @user.github_connection.destroy!
    assert_raises(ExportToGithubJob::TokenRevoked) do
      ExportToGithubJob.perform_now(@project.id)
    end
    # Guard caught by rescue → state marked :failed so the user sees why.
    assert_equal "failed", @project.reload.export_state
  end

  # --- token-leak invariant on success path ----------------------------

  test "successful run: no system call ever sees the token in remote-add/set-url" do
    repo_response = OpenStruct.new(full_name: "octocat/exportable-project")
    system_calls = []

    with_octokit_stub(repo_response, []) do
      with_system_stub(system_calls) do
        with_open3_stub([], success: true) do
          ExportToGithubJob.perform_now(@project.id, repo_name: "x")
        end
      end
    end

    system_calls.each do |cmd|
      next unless cmd.include?("git remote")
      refute_match(/gho_test_token|x-access-token/, cmd,
                   "git remote ops must never carry the token (got: #{cmd})")
    end
  end

  private

  def with_octokit_stub(repo_response, calls, raise_with: nil)
    fake_client_class = Class.new do
      attr_reader :access_token
      define_method(:initialize) { |access_token:| @access_token = access_token }
      define_method(:create_repository) do |name, **options|
        calls << { token: @access_token, name: name, options: options }
        raise raise_with if raise_with
        repo_response
      end
    end

    Octokit.singleton_class.alias_method(:_orig_client, :Client) if Octokit.respond_to?(:Client)
    original = Octokit.const_get(:Client)
    Octokit.send(:remove_const, :Client)
    Octokit.const_set(:Client, fake_client_class)

    yield
  ensure
    Octokit.send(:remove_const, :Client)
    Octokit.const_set(:Client, original)
  end

  def with_system_stub(calls)
    job_class = ExportToGithubJob
    job_class.class_eval do
      alias_method :__orig_run!, :run!
      define_method(:run!) do |workspace, argv, allow_fail: false|
        # Render argv as a single string for assertions that grep for "git remote add" / token presence.
        rendered = Array(argv).join(" ")
        calls << "cd #{workspace} && #{rendered}"
      end
    end

    yield
  ensure
    job_class.class_eval do
      alias_method :run!, :__orig_run!
      remove_method :__orig_run!
    end
  end

  def with_open3_stub(calls, success:, stderr: "")
    fake_status = OpenStruct.new(success?: success, exitstatus: success ? 0 : 1)

    Open3.singleton_class.alias_method(:_orig_capture3, :capture3)
    Open3.define_singleton_method(:capture3) do |*args|
      env = args.first.is_a?(Hash) ? args.shift : {}
      calls << { env: env, args: args }
      [ "", stderr, fake_status ]
    end

    yield
  ensure
    Open3.singleton_class.alias_method(:capture3, :_orig_capture3)
    Open3.singleton_class.send(:remove_method, :_orig_capture3)
  end
end
