require "shellwords"

module Preview
  class PreviewManager
    MEMORY_LIMIT = "512m"
    CPU_LIMIT    = "0.5"
    PIDS_LIMIT   = 100
    NETWORK      = "preview-internal"
    BASE_TAG     = "preview-base:latest"
    BUILD_TIMEOUT_SECONDS  = 8 * 60
    HEALTH_TIMEOUT_SECONDS = 60
    HEALTH_INTERVAL_SECONDS = 1
    ERROR_TRUNCATE = 2_000

    Result = Struct.new(:ok, :stdout, :stderr, :exit_code, keyword_init: true)

    # health_timeout / health_interval are injectable so unit tests can
    # exercise the timeout branch without sleeping for real (Minitest 6
    # dropped Object#stub, so per-instance overrides are the pattern).
    def initialize(runner: SystemRunner.new,
                   health_timeout: HEALTH_TIMEOUT_SECONDS,
                   health_interval: HEALTH_INTERVAL_SECONDS)
      @runner          = runner
      @health_timeout  = health_timeout
      @health_interval = health_interval
    end

    # Idempotent. If a preview exists for this project, stop it first.
    def start(project)
      stop(project) if project.preview_container_id.present?

      ensure_network!

      project.update!(
        preview_state: :starting,
        preview_started_at: Time.current,
        preview_error: nil
      )
      broadcast(project)

      tag = build_image(project)
      container_id = run_container(project, tag)
      project.update!(preview_container_id: container_id)

      health_check!(project)

      project.update!(preview_state: :running)
      ActiveSupport::Notifications.instrument(
        "preview.ready",
        project_id: project.id, url: project.preview_url
      )
      broadcast(project)
    rescue => e
      handle_failure(project, e)
    end

    def stop(project)
      cid = project.preview_container_id
      if cid.present?
        @runner.run("docker", "rm", "-f", cid)
        @runner.run("docker", "image", "rm", "-f", project_tag(project))
      end
      project.update!(
        preview_state: :stopped,
        preview_container_id: nil,
        preview_started_at: nil,
        preview_error: nil
      )
      broadcast(project)
    end

    # Step 3 smoke test on Docker Desktop / macOS confirmed `--internal` networks
    # silently drop `-p` host port mappings (vpnkit limitation). Plan's fallback:
    # create a non-internal network. Cost: containers reach outbound internet.
    # Phase 4 will reintroduce strict egress isolation on a Linux production
    # host where `--internal` actually works with port-publish.
    def self.ensure_network!(runner: SystemRunner.new)
      result = runner.run("docker", "network", "inspect", NETWORK, capture: true)
      return if result.ok
      runner.run("docker", "network", "create", NETWORK)
    end

    def ensure_network! = self.class.ensure_network!(runner: @runner)

    # Boot-time recovery. The Rails process may have been killed while a
    # preview was running; the DB row says :running but the container is
    # detached from any Ruby supervisor. Force-stop any preview-* containers
    # and reset rows so the UI shows truth.
    #
    # Wrapped in rescue so a missing Docker (CI, fresh machine) does not
    # crash boot for non-preview workflows.
    #
    # Filter strategy: `docker ps --filter name=...` does substring matching
    # by default, and regex-anchor support varies across engine versions —
    # `name=^preview-` is unreliable. Instead list everything and prefix-match
    # in Ruby against `{{.Names}}` output (one name per line).
    PREVIEW_CONTAINER_PREFIX = "preview-"
    private_constant :PREVIEW_CONTAINER_PREFIX

    def self.reset_orphans!(runner: SystemRunner.new)
      list = runner.run("docker", "ps", "-a", "--format", "{{.Names}}", capture: true)
      names = list.ok ? list.stdout.split("\n").map(&:strip).reject(&:empty?) : []
      orphans = names.select { |n| n.start_with?(PREVIEW_CONTAINER_PREFIX) }
      orphans.each { |name| runner.run("docker", "rm", "-f", name) }

      Project.where(preview_state: %i[starting running]).find_each do |project|
        project.update!(
          preview_state: :stopped,
          preview_container_id: nil,
          preview_started_at: nil,
          preview_error: "Reset on boot — process restarted while preview was running"
        )
      end
    rescue => e
      Rails.logger.error("[PreviewManager.reset_orphans!] #{e.class}: #{e.message}")
    end

    private

    # Single tag per project; Docker layer cache invalidates on COPY content
    # hash, so a stable tag is fine. `:latest` is overwritten on each rebuild.
    def project_tag(project)
      "preview-#{project.id}:latest"
    end

    def build_image(project)
      tag = project_tag(project)
      result = @runner.run(
        "docker", "build",
        "-t", tag,
        "--build-arg", "BASE_TAG=#{BASE_TAG}",
        "-f", Rails.root.join("lib/preview/Dockerfile").to_s,
        project.workspace_path,
        capture: true,
        timeout: BUILD_TIMEOUT_SECONDS
      )
      raise BuildError, result.stderr unless result.ok
      tag
    end

    def run_container(project, tag)
      port = project.preview_port
      result = @runner.run(
        "docker", "run", "-d",
        "--name", "preview-#{project.id}",
        "--memory=#{MEMORY_LIMIT}",
        "--memory-swap=#{MEMORY_LIMIT}",
        "--cpus=#{CPU_LIMIT}",
        "--pids-limit=#{PIDS_LIMIT}",
        "--cap-drop=ALL",
        "--security-opt=no-new-privileges",
        "--network=#{NETWORK}",
        "--read-only",
        "--tmpfs", "/tmp:size=64m",
        "--tmpfs", "/app/tmp:size=64m",
        # /app/log must be writable for Rails to open development.log even
        # though we also set RAILS_LOG_TO_STDOUT — the logger probes/touches
        # the file at boot before honoring the env var.
        "--tmpfs", "/app/log:size=16m",
        "-p", "#{port}:3000",
        # Rails 8's default sqlite path is `storage/development.sqlite3`, not
        # `db/`. Mounting storage/ keeps the database (and any uploaded files
        # that Active Storage might write here) persistent across container
        # rebuilds.
        "-v", "#{File.join(project.workspace_path, 'storage')}:/app/storage",
        "-e", "RAILS_LOG_TO_STDOUT=1",
        tag,
        capture: true
      )
      raise RunError, result.stderr unless result.ok
      result.stdout.strip
    end

    def health_check!(project)
      url = "http://localhost:#{project.preview_port}/up"
      deadline = Time.current + @health_timeout
      loop do
        return if curl_ok?(url)
        raise HealthcheckTimeout, "no /up after #{@health_timeout}s" if Time.current > deadline
        sleep @health_interval
      end
    end

    def curl_ok?(url)
      result = @runner.run("curl", "-fsS", "-o", "/dev/null", "-m", "2", url, capture: true)
      result.ok
    end

    def handle_failure(project, error)
      Rails.logger.error("[PreviewManager] #{error.class}: #{error.message}")
      cid = project.preview_container_id
      @runner.run("docker", "rm", "-f", cid) if cid.present?
      @runner.run("docker", "image", "rm", "-f", project_tag(project))
      project.update!(
        preview_state: :failed,
        preview_container_id: nil,
        preview_error: error.message.to_s.first(ERROR_TRUNCATE)
      )
      broadcast(project)
    end

    def broadcast(project)
      Turbo::StreamsChannel.broadcast_replace_to(
        project,
        target: "preview",
        partial: "previews/pane",
        locals: { project: project }
      )
    end

    class BuildError < StandardError; end
    class RunError < StandardError; end
    class HealthcheckTimeout < StandardError; end
  end
end
