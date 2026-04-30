require "shellwords"
require "open3"

class ExecuteInstructionJob < ApplicationJob
  queue_as :generation

  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = project.workspace_path

    prepare_workspace(workspace) unless project.workspace_initialized?
    init_rails_app(workspace) unless File.exist?(File.join(workspace, "Gemfile"))
    init_docs_baseline(workspace) unless File.exist?(File.join(workspace, "docs"))

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
        "git init -q && git add -A && " \
        "git -c user.email=generator@local -c user.name='Rails App Generator' " \
        "commit -q -m 'chore: skeleton baseline'"
      )
      raise "git init failed in #{workspace}" unless ok
    end

    # Roast spawns the `claude` CLI as the `generator` user (the binary refuses
    # to run --dangerously-skip-permissions as root). bundle install + git init
    # above ran as root and left workspace files root-owned; open up writes so
    # the generator user can edit them. New files claude creates will be
    # generator-owned, which is fine — root reads/writes them anyway, and
    # `git config --system --add safe.directory '*'` (set in the Dockerfile)
    # silences ownership warnings for subsequent root-side git ops.
    #
    # master.key stays 0600 (root-only) — generator never needs to decrypt
    # credentials, only the preview container does, and that runs separately.
    FileUtils.chmod_R("a+rwX", workspace)
    File.chmod(0o600, master_key_path)
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

  def init_docs_baseline(workspace)
    docs_dir = File.join(workspace, "docs")
    FileUtils.mkdir_p(docs_dir)
    {
      "architecture.md"   => "# Architecture\n\n(empty — will be filled in by the first revision)\n",
      "conventions.md"    => "# Conventions\n\n(empty — will be filled in by the first revision)\n",
      "domain.md"         => "# Domain\n\n(empty — will be filled in by the first revision)\n",
      "revision_notes.md" => "# Revision notes\n\n"
    }.each { |name, content| File.write(File.join(docs_dir, name), content) }

    system(
      "cd #{Shellwords.escape(workspace)} && git add -A && " \
      "git commit -m 'docs: scaffolding baseline' --allow-empty"
    )
  end

  def execute_revision(revision, workspace)
    revision.update!(status: :generating, started_at: Time.current)
    ActiveSupport::Notifications.instrument("revision.started", revision_id: revision.id)

    api_key = revision.instruction.project.user.profile.openrouter_api_key
    raise "Project owner has no OpenRouter API key" if api_key.blank?

    env = {
      "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
      "RAILS_APP_GENERATOR_MODEL" => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet"),
      "OPENROUTER_API_KEY" => api_key
    }
    args = [
      roast_executable,
      Rails.root.join("lib/roast/revision_workflow.rb").to_s,
      "--",
      "revision_id=#{revision.id}",
      "revision_summary=#{revision.summary}",
      "revision_prompt=#{revision.prompt}"
    ]

    ok, exit_code, wall_seconds = run_roast_subprocess(env, args)

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
    [ok, exit_code, wall]
  end

  def git_head(workspace)
    `cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null`.strip
  end

  def roast_executable
    if Rails.env.production? || ENV["FORCE_OPENROUTER"].present?
      Rails.root.join("bin/roast-openrouter").to_s
    else
      Rails.root.join("bin/roast-claudesubscription").to_s
    end
  end
end
