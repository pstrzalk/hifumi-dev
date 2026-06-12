require "shellwords"
require "open3"
# lib/roast is excluded from autoload (config.autoload_lib) — the workflow DSL
# files abort() at top level when run outside a roast subprocess. Sandbox is a
# plain builder, safe to load, so require it explicitly.
require Rails.root.join("lib/roast/sandbox").to_s

class ExecuteInstructionJob < ApplicationJob
  queue_as :generation

  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = project.workspace_path

    prepare_workspace(workspace)                   unless project.workspace_initialized?
    init_rails_app(workspace)                      unless File.exist?(File.join(workspace, "Gemfile"))
    init_docs_baseline(workspace)                  unless File.exist?(File.join(workspace, "docs"))
    pick_frontend_template(workspace, instruction) unless File.exist?(File.join(workspace, "docs/frontend.md"))

    instruction.revisions.order(:position).each do |revision|
      execute_revision(revision, workspace)
      break if revision.failed?
    end

    final_phase = instruction.revisions.reload.all?(&:completed?) ? :completed : :failed
    instruction.update!(phase: final_phase)
    ActiveSupport::Notifications.instrument(
      "instruction.#{final_phase}",
      instruction_id: instruction.id
    )
  end

  private

  def prepare_workspace(workspace)
    FileUtils.mkdir_p(File.dirname(workspace))
  end

  def init_rails_app(workspace)
    FileUtils.mkdir_p(File.dirname(workspace))
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton')}/.",         workspace)
    FileUtils.cp_r("#{Rails.root.join('lib/preview/skeleton-overlay')}/.", workspace)

    # Pre-create log files so the first `rails generate` an agent runs doesn't
    # spit "Rails Error: Unable to access log file ... log/development.log".
    # bin/preview-regen-skeleton's rsync excludes log/, so the dir itself isn't
    # in the skeleton — mkdir_p is required, not just touch. Rails would create
    # the files on first use, but does so under a noisy WARN-level error before
    # falling back. relax_workspace_permissions at the bottom of this method
    # makes them world-writable.
    log_dir = File.join(workspace, "log")
    FileUtils.mkdir_p(log_dir)
    %w[development.log test.log].each do |name|
      FileUtils.touch(File.join(log_dir, name))
    end

    # Skeleton ships without master.key / credentials.yml.enc to avoid baking
    # a shared secret into git. Each workspace gets its own master.key here
    # via Rails' own helper (the same one `rails credentials:edit` uses);
    # credentials.yml.enc is created on demand if anyone runs `bin/rails
    # credentials:edit` inside the workspace.
    master_key_path = File.join(workspace, "config/master.key")
    File.write(master_key_path, ActiveSupport::EncryptedFile.generate_key)
    File.chmod(0o600, master_key_path)

    Bundler.with_unbundled_env do
      ok = system(
        subprocess_env,
        "cd #{Shellwords.escape(workspace)} && bundle install --jobs 4"
      )
      raise "bundle install failed in #{workspace}" unless ok

      ok = system(
        subprocess_env,
        "cd #{Shellwords.escape(workspace)} && " \
        "git init -q -b main && " \
        "git config user.email #{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} && " \
        "git config user.name #{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} && " \
        "git add -A && " \
        "git -c user.email=#{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} " \
        "-c user.name=#{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} " \
        "commit -q -m 'chore: skeleton baseline'"
      )
      raise "git init failed in #{workspace}" unless ok
    end

    relax_workspace_permissions(workspace)
  end

  # Roast spawns the `claude` CLI as the `generator` user (the binary refuses
  # to run --dangerously-skip-permissions as root). Anything Rails writes from
  # this job runs as root and would otherwise leave files root-owned 0644 —
  # which the generator-side agent can't edit, costing remediation turns when
  # it discovers it can't write to docs/ or Gemfile.lock. Open up writes after
  # every root-side mutation; new files claude creates will be generator-owned,
  # which is fine — root can still read/write them, and
  # `git config --system --add safe.directory '*'` (set in the Dockerfile)
  # silences ownership warnings for subsequent root-side git ops.
  #
  # master.key stays 0600 (root-only) — generator never needs to decrypt
  # credentials, only the preview container does, and that runs separately.
  def relax_workspace_permissions(workspace)
    FileUtils.chmod_R("a+rwX", workspace)
    master_key_path = File.join(workspace, "config/master.key")
    File.chmod(0o600, master_key_path) if File.exist?(master_key_path)
  end

  # Cwd for rails new / git / bundle is outside this repo (Project.workspace_root),
  # so the frum shim can't resolve Ruby from .ruby-version there. Prepend the
  # pinned Ruby's bin dir to PATH the same way bin/roast does.
  #
  # `.ruby-version` content carries the `ruby-` prefix (e.g. `ruby-4.0.2`) but
  # frum's directory layout omits it (`~/.frum/versions/4.0.2/`), so strip.
  def subprocess_env
    ruby_version = File.read(Rails.root.join(".ruby-version")).strip.delete_prefix("ruby-")
    frum_bin = File.join(Dir.home, ".frum", "versions", ruby_version, "bin")
    return {} unless File.directory?(frum_bin)
    { "PATH" => "#{frum_bin}:#{ENV.fetch('PATH', '')}" }
  end

  # `instruction.user_intent` is the synthesis the chat agent passes to
  # create_application — typically 1-3 sentences of substantive signal. Falls
  # back to project.name (the truncated first chat message) if blank, which
  # can happen when the agent skips clarifications and the input was very
  # short. The picker writes a NEW file (docs/frontend.md) and rewrites the
  # layout as root, so we need relax_workspace_permissions afterwards —
  # otherwise the W2.6 update_docs `claude` agent (running as the generator
  # user) hits EACCES the first time it tries to Edit frontend.md.
  def pick_frontend_template(workspace, instruction)
    api_key = instruction.project.user.profile.openrouter_api_key
    raise "Project owner has no OpenRouter API key" if api_key.blank?

    description = instruction.user_intent.presence || instruction.project.name

    Templates::Picker.call(
      workspace: workspace,
      description: description,
      openrouter_api_key: api_key,
      model: instruction.project.template_model
    )

    relax_workspace_permissions(workspace) if File.directory?(workspace)
  end

  def init_docs_baseline(workspace)
    docs_dir = File.join(workspace, "docs")
    FileUtils.mkdir_p(docs_dir)
    {
      "architecture.md"   => "# Architecture\n\n(empty — will be filled in by the first revision)\n",
      "conventions.md"    => "# Conventions\n\n(empty — will be filled in by the first revision)\n",
      "domain.md"         => "# Domain\n\n(empty — will be filled in by the first revision)\n",
      "revision_notes.md" => "# Revision notes\n\n"
    }.each { |name, content| File.write(File.join(docs_dir, name), content) }

    # Author identity comes from the repo-local config set in init_rails_app.
    system(
      "cd #{Shellwords.escape(workspace)} && git add -A && " \
      "git commit -m 'docs: scaffolding baseline' --allow-empty"
    )

    relax_workspace_permissions(workspace)
  end

  def execute_revision(revision, workspace)
    revision.update!(status: :generating, started_at: Time.current)
    ActiveSupport::Notifications.instrument("revision.started", revision_id: revision.id)

    api_key = revision.instruction.project.user.profile.openrouter_api_key
    raise "Project owner has no OpenRouter API key" if api_key.blank?

    # The generator container itself runs RAILS_ENV=production, but the
    # *workspace* is a fresh, unconfigured Rails app — booting in production
    # blows up on a missing secret_key_base before the agent can do anything.
    # Override RAILS_ENV for the entire roast subprocess tree (verify steps,
    # the claude CLI, and any rails-generate the agent invokes) so workspace
    # commands land in development.
    env = {
      "HIFUMI_DEV_WORKSPACE" => workspace,
      "OPENROUTER_API_KEY" => api_key,
      "RAILS_ENV" => "development"
    }.merge(roast_model_env(revision.instruction.project))

    ok, exit_code, wall_seconds = run_roast_subprocess(env, revision_command(revision, workspace, env))

    metrics = {
      wall_seconds: wall_seconds,
      exit_code: exit_code,
      git_sha: git_head(workspace)
    }

    if ok
      revision.update!(
        status: :completed,
        finished_at: Time.current,
        git_sha: metrics[:git_sha],
        metrics: metrics
      )
      ActiveSupport::Notifications.instrument(
        "revision.completed",
        revision_id: revision.id,
        git_sha: metrics[:git_sha]
      )
    else
      revision.update!(status: :failed, finished_at: Time.current, metrics: metrics)
      ActiveSupport::Notifications.instrument(
        "revision.failed",
        revision_id: revision.id,
        error: "exit #{exit_code}"
      )
    end
  end

  # Test seam — stubbed in unit tests, real in Step 7's integration test.
  # popen3 (vs system+inherited TTY) lets us scrub each output line before it
  # hits Rails.logger, so a key echoed by the subprocess can't reach prod logs.
  def run_roast_subprocess(env, args)
    started = Time.current
    exit_code = nil

    Open3.popen3(env, *args) do |stdin, stdout, stderr, wait_thread|
      stdin.close
      threads = [
        Thread.new { stdout.each_line { |line| Rails.logger.info(LogScrub.call(line.chomp)) } },
        Thread.new { stderr.each_line { |line| Rails.logger.error(LogScrub.call(line.chomp)) } }
      ]
      threads.each(&:join)
      exit_code = wait_thread.value.exitstatus
    end

    ok = exit_code == 0
    wall = (Time.current - started).round(2)
    [ ok, exit_code, wall ]
  end

  def git_head(workspace)
    `cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null`.strip
  end

  # The roast invocation for a revision. In production (and when explicitly
  # forced) it is wrapped in a throwaway, single-tenant container so the
  # codegen agent cannot reach other tenants' workspaces or the host Docker
  # socket (see Roast::Sandbox). env is passed so the same keys are forwarded
  # into the container by name; the values stay in the spawning process's
  # environment (no argv/`ps` leak).
  def revision_command(revision, workspace, env)
    roast_command = [
      roast_executable,
      Rails.root.join("lib/roast/revision_workflow.rb").to_s,
      "--",
      "revision_id=#{revision.id}",
      "revision_summary=#{revision.summary}",
      "revision_prompt=#{revision.prompt}"
    ]
    return roast_command unless sandboxed?

    Roast::Sandbox.wrap(
      command: roast_command,
      env_keys: env.keys,
      workspace: workspace,
      name: "agent-revision-#{revision.id}"
    )
  end

  def roast_executable
    if use_openrouter?
      Rails.root.join("bin/roast-openrouter").to_s
    else
      Rails.root.join("bin/roast-claudesubscription").to_s
    end
  end

  # Per-project model selection applies only on the OpenRouter path —
  # bin/roast-claudesubscription (local dev) keeps the claude CLI's alias
  # defaults, and an explicit HIFUMI_DEV_* var in the operator's ENV still
  # wins on either path so a developer can pin models when testing.
  #
  # The claudesubscription branch deliberately omits HIFUMI_DEV_DOCS_MODEL:
  # WorkflowEnv's "haiku" alias default covers the docs agent there, and a
  # full OpenRouter id from the project would not resolve against the real
  # Anthropic API the subscription transport talks to.
  def roast_model_env(project)
    unless use_openrouter?
      return { "HIFUMI_DEV_MODEL" => ENV.fetch("HIFUMI_DEV_MODEL", "sonnet") }
    end

    {
      "HIFUMI_DEV_MODEL" => ENV["HIFUMI_DEV_MODEL"].presence || project.code_model,
      "HIFUMI_DEV_DOCS_MODEL" => ENV["HIFUMI_DEV_DOCS_MODEL"].presence || project.docs_model
    }
  end

  # The OpenRouter transport (vs the dev Claude-subscription one) — also picks
  # the roast wrapper and turns on per-project model selection. Sandboxing
  # implies it: the throwaway image's bundled `claude` has no host OAuth creds,
  # so a sandboxed run must go through OpenRouter.
  def use_openrouter?
    Rails.env.production? || ENV["FORCE_OPENROUTER"].present? || sandboxed?
  end

  # Multi-tenant isolation is a production concern. Dev is single-tenant and
  # uses the Claude subscription transport (host OAuth, no container), so the
  # default there is to run roast directly. FORCE_AGENT_SANDBOX exercises the
  # container path locally (needs Docker + HIFUMI_AGENT_IMAGE + an OpenRouter key).
  def sandboxed?
    Rails.env.production? || ENV["FORCE_AGENT_SANDBOX"].present?
  end
end
