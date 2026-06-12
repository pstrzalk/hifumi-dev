require "test_helper"
require Rails.root.join("lib/roast/sandbox").to_s

class Roast::SandboxTest < ActiveSupport::TestCase
  WORKSPACE = "/var/lib/hifumi-dev/workspaces/project_42".freeze

  def wrap(**overrides)
    Roast::Sandbox.wrap(**{
      command: [ "/rails/bin/roast-openrouter", "/rails/lib/roast/revision_workflow.rb", "--", "revision_id=7" ],
      env_keys: [ "OPENROUTER_API_KEY", "HIFUMI_DEV_WORKSPACE", "RAILS_ENV" ],
      workspace: WORKSPACE,
      name: "agent-revision-7",
      image: "registry/hifumi-dev:latest"
    }.merge(overrides))
  end

  test "produces a docker run --rm invocation of the given image and command" do
    argv = wrap
    assert_equal %w[docker run --rm], argv.first(3)
    # image immediately precedes the wrapped command
    image_idx = argv.index("registry/hifumi-dev:latest")
    assert_equal "/rails/bin/roast-openrouter", argv[image_idx + 1]
    assert_equal "revision_id=7", argv.last
  end

  test "mounts ONLY this workspace at the same path — no workspace_root, no sibling projects" do
    argv = wrap
    mounts = argv.each_cons(2).select { |flag, _| flag == "-v" }.map(&:last)
    assert_equal [ "#{WORKSPACE}:#{WORKSPACE}" ], mounts
  end

  test "never mounts the docker socket (closes the container-escape path)" do
    assert_not wrap.any? { |arg| arg.include?("docker.sock") },
      "the throwaway must not be able to reach the host Docker daemon"
  end

  test "runs the whole container as the unprivileged generator user" do
    assert_includes wrap, "--user=#{Roast::Sandbox::USER}"
  end

  test "is not privileged and drops every capability — no cap-adds at all" do
    argv = wrap
    assert_not argv.include?("--privileged")
    assert_includes argv, "--cap-drop=ALL"
    assert_includes argv, "--security-opt=no-new-privileges"
    assert_empty argv.grep(/\A--cap-add/),
      "non-root + uniform uid needs no capabilities; SETUID/SETGID were only for the runuser path"
  end

  test "applies resource ceilings" do
    argv = wrap
    assert_includes argv, "--memory=#{Roast::Sandbox::MEMORY_LIMIT}"
    assert_includes argv, "--cpus=#{Roast::Sandbox::CPU_LIMIT}"
    assert_includes argv, "--pids-limit=#{Roast::Sandbox::PIDS_LIMIT}"
  end

  test "forwards env vars BY NAME only — values never enter argv (no ps/argv leak)" do
    argv = wrap(env_keys: [ "OPENROUTER_API_KEY", "RAILS_ENV" ])
    # each key appears as a valueless `-e NAME` pair
    forwarded = argv.each_cons(2).select { |flag, _| flag == "-e" }.map(&:last)
    assert_equal [ "OPENROUTER_API_KEY", "RAILS_ENV" ], forwarded
    # no `-e NAME=value` form anywhere
    assert_not argv.any? { |arg| arg.match?(/\A[A-Z_]+=.+/) },
      "env must be forwarded by name so Docker reads values from the caller's environment"
  end

  test "names the container for observability and targeted cleanup" do
    assert_includes wrap(name: "agent-revision-99"), "agent-revision-99"
  end

  test "image defaults to HIFUMI_AGENT_IMAGE" do
    with_env("HIFUMI_AGENT_IMAGE" => "from-env:tag") do
      argv = Roast::Sandbox.wrap(
        command: [ "roast" ], env_keys: [], workspace: WORKSPACE, name: "n"
      )
      assert_includes argv, "from-env:tag"
    end
  end

  test "raises a clear error when no agent image is configured" do
    with_env("HIFUMI_AGENT_IMAGE" => nil) do
      error = assert_raises(Roast::Sandbox::MissingImage) do
        Roast::Sandbox.wrap(command: [ "roast" ], env_keys: [], workspace: WORKSPACE, name: "n")
      end
      assert_match(/HIFUMI_AGENT_IMAGE/, error.message)
    end
  end
end
