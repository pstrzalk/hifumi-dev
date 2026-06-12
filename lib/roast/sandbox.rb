# frozen_string_literal: true

# Per-instruction isolation for the codegen agent.
#
# The revision workflow runs the `claude` CLI with skip_permissions! — every
# Bash/Edit tool call is auto-approved, and the user's chat text reaches the
# agent prompt. Treat that as untrusted code execution: run each revision in a
# throwaway container scoped to a single tenant instead of in the shared
# generator container.
#
# This module wraps the roast invocation in a throwaway `docker run` that mounts
# ONLY this project's workspace and does NOT mount the Docker socket. Other
# tenants' workspaces are absent from the container's filesystem, and the agent
# has no path to the host daemon. It is the same container pattern the preview
# side already uses (lib/preview/preview_manager.rb), applied to generation.
#
# Builder only — returns the argv; ExecuteInstructionJob spawns it through the
# existing popen3 → LogScrub → Rails.logger path. Kept free of side effects so
# the argv can be unit-tested without Docker.
module Roast
  module Sandbox
    # Generation is heavier than preview (bundle install, rails generators,
    # the test suite) so the ceilings are higher than PreviewManager's. Tunable.
    MEMORY_LIMIT = "4g"
    CPU_LIMIT    = "2"
    PIDS_LIMIT   = 512

    class MissingImage < StandardError; end

    module_function

    # Full `docker run` argv that executes `command` inside the throwaway.
    #
    # - command:    the roast invocation, e.g. [bin/roast-openrouter, workflow, "--", kwargs...]
    # - env_keys:   names of env vars to forward INTO the container. Only names
    #               are placed in argv (`-e NAME`); Docker reads the values from
    #               the spawning process's own environment, so secrets like
    #               OPENROUTER_API_KEY never appear in argv / `ps`.
    # - workspace:  absolute host path of this project's workspace; bind-mounted
    #               at the same path so HIFUMI_DEV_WORKSPACE resolves unchanged.
    # - name:       container name (observability + targeted cleanup).
    def wrap(command:, env_keys:, workspace:, name:, image: self.image)
      [
        "docker", "run", "--rm",
        "--name", name,
        # Drop every Linux capability, then add back only the two the baked
        # `claude` wrapper needs: it runs as root and re-execs the CLI as the
        # unprivileged `generator` user via `runuser`, which requires SETUID/
        # SETGID. (no-new-privileges + these two need a runtime smoke test on
        # the Linux host. The tenant isolation does not depend on the cap set;
        # it comes from the mount scoping below, so loosening caps if the agent
        # fails to start is safe.)
        "--cap-drop=ALL",
        "--cap-add=SETUID",
        "--cap-add=SETGID",
        "--security-opt=no-new-privileges",
        "--memory=#{MEMORY_LIMIT}",
        "--memory-swap=#{MEMORY_LIMIT}",
        "--cpus=#{CPU_LIMIT}",
        "--pids-limit=#{PIDS_LIMIT}",
        # Only this workspace — no workspace_root, no sibling projects, no
        # /var/run/docker.sock. This is the load-bearing isolation control.
        "-v", "#{workspace}:#{workspace}",
        *env_keys.flat_map { |key| [ "-e", key.to_s ] },
        image,
        *command
      ]
    end

    # The generator's own application image — it already carries the roast gem,
    # the `claude` binary + openrouter wrapper, Ruby/Bundler and lib/roast.
    # Sourced from ENV so the deploy pins it to the running release; raises
    # rather than silently running a stale/unknown image.
    def image
      ENV["HIFUMI_AGENT_IMAGE"].presence ||
        raise(MissingImage, "HIFUMI_AGENT_IMAGE must be set to run the codegen agent in an isolated container")
    end
  end
end
