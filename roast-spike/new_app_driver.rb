#!/usr/bin/env ruby
# frozen_string_literal: true

# W1 driver: rails new + pętla shellująca revision_workflow.rb per rewizja.
# Odpowiednik przyszłego Solid Queue joba z głównej apki generatora.
#
# Usage:
#   bin/new_app --plan todo-list --app-name todo-spike --workspace /tmp/spike [--model sonnet]
#
# Efekt:
#   - Tworzy Rails app w <workspace>/<app-name>
#   - Wykonuje każdą rewizję z planu przez `bundle exec roast revision_workflow.rb`
#   - Loguje czas i status per rewizja, zapisuje metrics.json

require "json"
require "optparse"
require "shellwords"
require "time"

require_relative "plans"

class NewAppDriver
  SPIKE_DIR = File.expand_path(__dir__)

  def initialize(plan_name:, app_name:, workspace:, model: "sonnet", dry_run: false)
    @plan = Plans.fetch(plan_name)
    @plan_name = plan_name
    @app_name = app_name
    @workspace_root = File.expand_path(workspace)
    @workspace = File.join(@workspace_root, app_name)
    @model = model
    @dry_run = dry_run
    @metrics = { plan: plan_name, app_name: app_name, model: model, revisions: [], started_at: Time.now.iso8601 }
  end

  def run
    log "Plan: #{@plan_name} (#{@plan.size} revisions)"
    log "Workspace: #{@workspace}"
    log "Model: #{@model}"
    log "Dry run: #{@dry_run}"

    prepare_workspace

    rails_new
    init_git_and_docs

    @plan.each_with_index do |revision, idx|
      execute_revision(revision, idx + 1)
    end

    @metrics[:finished_at] = Time.now.iso8601
    @metrics[:total_wall_seconds] = @metrics[:revisions].sum { |r| r[:wall_seconds] || 0 }
    @metrics[:all_succeeded] = @metrics[:revisions].all? { |r| r[:status] == "completed" }

    write_metrics
    print_summary
    @metrics[:all_succeeded]
  end

  private

  def prepare_workspace
    if Dir.exist?(@workspace)
      log "Workspace already exists, removing: #{@workspace}"
      FileUtils.rm_rf(@workspace)
    end
    FileUtils.mkdir_p(@workspace_root)
  end

  def rails_new
    log "[W1.1] rails new #{@app_name}"
    return log("(dry-run) skipping rails new") if @dry_run

    cmd = "cd #{Shellwords.escape(@workspace_root)} && " \
          "rails new #{Shellwords.escape(@app_name)} " \
          "--css tailwind --database sqlite3 --skip-jbuilder --skip-kamal --skip-ci"
    unless system(cmd)
      abort "rails new failed. Aborting."
    end
  end

  def init_git_and_docs
    log "[W1.1b] initializing docs/ and committing baseline"
    return if @dry_run

    docs_dir = File.join(@workspace, "docs")
    FileUtils.mkdir_p(docs_dir)
    File.write(File.join(docs_dir, "architecture.md"), "# Architecture\n\n(pusta — zostanie wypełniona przez pierwszą rewizję)\n")
    File.write(File.join(docs_dir, "conventions.md"), "# Conventions\n\n(pusta — zostanie wypełniona przez pierwszą rewizję)\n")
    File.write(File.join(docs_dir, "domain.md"), "# Domain\n\n(pusta — zostanie wypełniona przez pierwszą rewizję)\n")
    File.write(File.join(docs_dir, "revision_notes.md"), "# Revision notes\n\n")

    system("cd #{Shellwords.escape(@workspace)} && git add -A && git commit -m 'docs: scaffolding baseline' --allow-empty")
  end

  def execute_revision(revision, idx)
    log ""
    log "=" * 70
    log "[W1.5 #{idx}/#{@plan.size}] #{revision[:summary]}"
    log "=" * 70

    started = Time.now
    status, exit_code = dispatch_roast(revision, idx)
    wall = Time.now - started

    entry = {
      index: idx,
      summary: revision[:summary],
      status: status,
      exit_code: exit_code,
      wall_seconds: wall.round(2),
      git_sha: git_head(@workspace)
    }
    @metrics[:revisions] << entry

    log "[W1.5 #{idx}/#{@plan.size}] #{status.upcase} in #{wall.round(1)}s"

    if status != "completed"
      log "[W1] Revision failed — stopping pipeline."
      raise "Revision #{idx} failed with exit code #{exit_code}"
    end
  end

  def dispatch_roast(revision, idx)
    return ["completed", 0] if @dry_run

    env = {
      "REVISION_WORKSPACE" => @workspace,
      "CLAUDE_MODEL" => @model
    }

    args = [
      "bundle", "exec", "roast", "revision_workflow.rb",
      "--",
      "revision_id=#{idx}",
      "revision_summary=#{revision[:summary]}",
      "revision_prompt=#{revision[:prompt]}"
    ]

    log "[W1] dispatching: #{args.join(" ")}"
    ok = system(env, *args, chdir: SPIKE_DIR)
    exit_code = $?.exitstatus
    [ok ? "completed" : "failed", exit_code]
  end

  def git_head(workspace)
    `cd #{Shellwords.escape(workspace)} && git rev-parse HEAD 2>/dev/null`.strip
  end

  def write_metrics
    metrics_path = File.join(SPIKE_DIR, "tmp", "metrics_#{@plan_name}_#{Time.now.to_i}.json")
    FileUtils.mkdir_p(File.dirname(metrics_path))
    File.write(metrics_path, JSON.pretty_generate(@metrics))
    log "[W1] Metrics written: #{metrics_path}"
  end

  def print_summary
    log ""
    log "=" * 70
    log "PIPELINE SUMMARY"
    log "=" * 70
    log "Plan: #{@plan_name}"
    log "Workspace: #{@workspace}"
    log "Total wall time: #{@metrics[:total_wall_seconds].round(1)}s"
    log ""
    @metrics[:revisions].each do |r|
      log "  [#{r[:index]}] #{r[:status].upcase.ljust(10)} #{r[:wall_seconds].to_s.rjust(6)}s  #{r[:summary]}"
    end
    log ""
    log "Git log:"
    puts `cd #{Shellwords.escape(@workspace)} && git log --oneline 2>&1`
  end

  def log(msg)
    puts "[driver] #{msg}"
  end
end

# --- CLI ---

if __FILE__ == $PROGRAM_NAME
  require "fileutils"

  options = { model: "sonnet", dry_run: false }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: new_app_driver.rb [options]"
    opts.on("--plan NAME", "Plan name (available: #{Plans.available.join(", ")})") { |v| options[:plan] = v }
    opts.on("--app-name NAME", "Rails app name") { |v| options[:app_name] = v }
    opts.on("--workspace PATH", "Parent directory for Rails app") { |v| options[:workspace] = v }
    opts.on("--model NAME", "Claude model (default: sonnet)") { |v| options[:model] = v }
    opts.on("--dry-run", "Don't actually run rails new or Claude") { options[:dry_run] = true }
    opts.on("-h", "--help", "Show help") { puts opts; exit }
  end
  parser.parse!

  %i[plan app_name workspace].each do |k|
    unless options[k]
      warn "Missing required option: --#{k.to_s.tr("_", "-")}"
      warn parser.help
      exit 1
    end
  end

  success = NewAppDriver.new(
    plan_name: options[:plan],
    app_name: options[:app_name],
    workspace: options[:workspace],
    model: options[:model],
    dry_run: options[:dry_run]
  ).run

  exit(success ? 0 : 1)
end
