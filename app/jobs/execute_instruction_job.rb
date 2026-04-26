require "shellwords"

class ExecuteInstructionJob < ApplicationJob
  queue_as :generation

  def perform(instruction_id)
    instruction = Instruction.find(instruction_id)
    project = instruction.project
    workspace = project.workspace_path

    prepare_workspace(workspace) unless project.workspace_initialized?
    rails_new(workspace) unless File.exist?(File.join(workspace, "Gemfile"))
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

  def rails_new(workspace)
    parent = File.dirname(workspace)
    app_name = File.basename(workspace)

    Bundler.with_unbundled_env do
      ok = system(
        subprocess_env,
        "cd #{Shellwords.escape(parent)} && " \
        "rails new #{Shellwords.escape(app_name)} " \
        "--css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci"
      )
      raise "rails new failed in #{parent} for #{app_name}" unless ok
    end
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

    env = {
      "RAILS_APP_GENERATOR_WORKSPACE" => workspace,
      "RAILS_APP_GENERATOR_MODEL" => ENV.fetch("RAILS_APP_GENERATOR_MODEL", "sonnet")
    }
    args = [
      Rails.root.join("bin/roast").to_s,
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
  def run_roast_subprocess(env, args)
    started = Time.current
    ok = system(env, *args)
    exit_code = $?.exitstatus
    wall = (Time.current - started).round(2)
    [ok, exit_code, wall]
  end

  def git_head(workspace)
    `cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null`.strip
  end
end
