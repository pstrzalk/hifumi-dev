require "open3"
require "shellwords"

class ExportToGithubJob < ApplicationJob
  queue_as :default

  class TokenRevoked     < StandardError; end
  class RepoCreateFailed < StandardError; end
  class PushDiverged     < StandardError; end
  class WorkspaceMissing < StandardError; end

  # repo_name + private_repo only matter on first export. Subsequent
  # invocations push to the existing project.github_repo_full_name.
  def perform(project_id, repo_name: nil, private_repo: true)
    project = Project.find(project_id)
    raise WorkspaceMissing, "workspace not initialized" unless project.workspace_initialized?

    connection = project.user.github_connection
    raise TokenRevoked, "no github connection" unless connection&.connected?

    project.update!(export_state: :exporting, export_error: nil)
    broadcast(project)

    if project.github_repo_full_name.blank?
      repo = create_repo(connection.access_token, repo_name, private_repo)
      project.update!(github_repo_full_name: repo.full_name)
    end

    push!(project, connection.access_token)

    project.update!(export_state: :exported, exported_at: Time.current)
    broadcast(project)
  rescue Octokit::Unauthorized
    fail!(project, TokenRevoked.new("GitHub token was revoked. Please reconnect on your profile."))
  rescue Octokit::UnprocessableEntity => e
    # 422 from create_repository: name collision is the dominant cause.
    # Other 422s (invalid name characters, repo creation disabled, etc.) get
    # a generic message — we'd rather under-explain than mis-explain.
    msg = if e.message.to_s.match?(/name already exists/i)
      "A repository with that name already exists on your GitHub account."
    else
      "GitHub rejected the repository creation request."
    end
    fail!(project, RepoCreateFailed.new(msg))
  rescue PushDiverged => e
    fail!(project, e)
  rescue StandardError => e
    fail!(project, e)
  end

  private

  def create_repo(token, name, private_repo)
    client = Octokit::Client.new(access_token: token)
    client.create_repository(name, private: private_repo, auto_init: false)
  end

  def push!(project, token)
    workspace = project.workspace_path
    full_name = project.github_repo_full_name
    remote_url_with_token = "https://x-access-token:#{token}@github.com/#{full_name}.git"
    remote_url_clean      = "https://github.com/#{full_name}.git"

    # Pin a clean origin remote (no token in .git/config, ever) for the
    # user's later convenience (so `git push` from a checkout works once
    # they've added their own credentials).
    run!(workspace, ["git", "remote", "remove", "origin"], allow_fail: true)
    run!(workspace, ["git", "remote", "add", "origin", remote_url_clean])

    # Push using the token-bearing URL passed directly on the command line,
    # NOT via a stored remote — Open3 args don't touch disk, so a crash
    # mid-push can't leave the token in .git/config. The URL is in the
    # process's argv for the duration of the push (visible in `ps` to
    # other users on the host) — acceptable given the host is a single-
    # tenant container in production.
    stdout, stderr, status = Open3.capture3(
      { "GIT_TERMINAL_PROMPT" => "0" },
      "git", "-C", workspace, "push", remote_url_with_token, "main"
    )

    return if status.success?

    if stderr.match?(/non-fast-forward|rejected/i)
      raise PushDiverged, "Can't push: the GitHub repo has commits this app doesn't know about."
    elsif stderr.match?(/Authentication failed|Bad credentials/i)
      raise Octokit::Unauthorized
    else
      raise "git push failed (exit #{status.exitstatus}): #{stderr.lines.last(5).join.strip}"
    end
  end

  def run!(workspace, argv, allow_fail: false)
    Bundler.with_unbundled_env do
      # Argv form (no shell) — Shellwords.escape elsewhere is moot.
      ok = system(*argv, chdir: workspace)
      raise "command failed: #{argv.inspect}" unless ok || allow_fail
    end
  end

  def fail!(project, error)
    if project
      project.update!(export_state: :failed, export_error: error.message)
      broadcast(project)
    end
    raise error
  end

  def broadcast(project)
    Turbo::StreamsChannel.broadcast_replace_to(
      project,
      target: "github_export_pane",
      partial: "github_exports/pane",
      locals: { project: project }
    )
  end
end
