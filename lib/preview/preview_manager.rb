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
      ensure_storage_writable!(project)
      container_id = run_container(project, tag)
      project.update!(preview_container_id: container_id)

      health_check!(project)
      register_with_proxy!(project) if Preview::Config.remote?

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

      if Preview::Config.remote? && cid.present?
        # Ignore errors — route may already be gone (kamal-proxy restarted,
        # never registered, or stop called twice). Capture stderr only for
        # the log; failure here must not block the docker rm below.
        @runner.run(
          "docker", "exec", "kamal-proxy",
          "kamal-proxy", "remove", "preview-#{project.id}",
          capture: true
        )
      end

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

    # In prod (`Preview::Config.remote?`) the network is `--internal`, which
    # blocks all outbound traffic from attached containers — gem dependencies
    # are baked at build time, so runtime egress is unnecessary. In dev we
    # skip `--internal` because Docker Desktop's vpnkit silently drops `-p`
    # host port mappings on internal networks (verified Phase 3 step 3).
    def self.ensure_network!(runner: SystemRunner.new)
      result = runner.run("docker", "network", "inspect", NETWORK, capture: true)
      return if result.ok

      args = ["docker", "network", "create"]
      args << "--internal" if Preview::Config.remote?
      args << NETWORK
      result = runner.run(*args, capture: true)
      raise "docker network create #{NETWORK} failed: #{result.stderr}" unless result.ok
    end

    def ensure_network! = self.class.ensure_network!(runner: @runner)

    # Boot-time reconciliation. The Rails process may have restarted (Kamal
    # deploy, manual `kamal app boot`, host reboot, OOM kill) while user
    # previews were running. Containers are managed by the host Docker
    # daemon, not the Rails process — they survive the restart and we must
    # NOT kill them just because the generator booted.
    #
    # Three categories:
    #   A) container live AND DB row :running with matching id  → leave alone
    #   B) container live but no DB row claims it (stale row was reset, or
    #      container started by some out-of-band path)          → kill, and
    #      remove the kamal-proxy route if remote
    #   C) DB row :starting/:running but no live container       → mark stopped
    #
    # Wrapped in rescue so a missing Docker (CI, fresh machine) does not
    # crash boot for non-preview workflows.
    PREVIEW_CONTAINER_PREFIX = "preview-"
    private_constant :PREVIEW_CONTAINER_PREFIX

    def self.reset_orphans!(runner: SystemRunner.new)
      list = runner.run("docker", "ps", "--format", "{{.Names}}", capture: true)
      live_names = list.ok ? list.stdout.split("\n").map(&:strip).reject(&:empty?) : []
      live_preview_names = live_names.select { |n| n.start_with?(PREVIEW_CONTAINER_PREFIX) }
      live_ids = live_preview_names
        .map { |n| n.sub(/^#{PREVIEW_CONTAINER_PREFIX}/, "").to_i }
        .reject(&:zero?)
        .to_set

      db_running_ids = Project.where(preview_state: %i[starting running]).pluck(:id).to_set

      # Category B: live container, no live DB row → orphan, kill it.
      orphan_ids = live_ids - db_running_ids
      orphan_ids.each do |id|
        name = "#{PREVIEW_CONTAINER_PREFIX}#{id}"
        runner.run("docker", "rm", "-f", name)
        if Preview::Config.remote?
          runner.run("docker", "exec", "kamal-proxy", "kamal-proxy", "remove", name)
        end
      end

      # Category C: DB row claims running but no live container → mark stopped.
      stale_ids = db_running_ids - live_ids
      Project.where(id: stale_ids.to_a).find_each do |project|
        project.update!(
          preview_state: :stopped,
          preview_container_id: nil,
          preview_started_at: nil,
          preview_error: "Container missing on boot — marked stopped"
        )
      end

      # Category A is a no-op: the live container keeps serving and the
      # kamal-proxy route persists in the proxy's process state across the
      # generator's restart.

      # Belt-and-braces: stopped/exited preview-* containers also reaped so
      # disk does not accumulate. They serve no traffic; safe to remove.
      stopped = runner.run("docker", "ps", "-a", "--filter", "status=exited", "--format", "{{.Names}}", capture: true)
      if stopped.ok
        stopped.stdout.split("\n").map(&:strip).each do |name|
          next unless name.start_with?(PREVIEW_CONTAINER_PREFIX)
          runner.run("docker", "rm", "-f", name)
        end
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

    # The preview container runs as root with --cap-drop=ALL, which strips
    # CAP_DAC_OVERRIDE — so root inside the container follows ordinary file
    # permission rules instead of bypassing them. The agent creates the SQLite
    # DB during a revision via the claude CLI (runuser'd to UID 1000), leaving
    # storage/development.sqlite3 mode 644 owned by 1000:1000. Without this
    # chmod, the preview container's UID-0 process can read but not write the
    # file, and the first INSERT fails with SQLITE_READONLY. ExecuteInstruction
    # Job#relax_workspace_permissions only runs at init, not after revisions,
    # so re-relax here right before each container boot.
    def ensure_storage_writable!(project)
      storage = File.join(project.workspace_path, "storage")
      return unless File.directory?(storage)
      FileUtils.chmod_R("a+rwX", storage)
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
      args = [
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
        "--tmpfs", "/app/log:size=16m"
      ]

      # In prod the container is reached via kamal-proxy on the internal
      # network (no host port mapping). In dev we publish so the iframe can
      # load `localhost:#{port}`.
      unless Preview::Config.remote?
        args.push("-p", "#{project.preview_port}:3000")
      end

      args.push(
        # Rails 8's default sqlite path is `storage/development.sqlite3`, not
        # `db/`. Mounting storage/ keeps the database (and any uploaded files
        # that Active Storage might write here) persistent across container
        # rebuilds.
        "-v", "#{File.join(project.workspace_path, 'storage')}:/app/storage",
        "-e", "RAILS_LOG_TO_STDOUT=1"
      )

      # Whitelist the kamal-proxy hostname in the generated app's
      # config.hosts (preview_iframe.rb initializer reads this). Only set in
      # remote mode; in dev the iframe loads via localhost:port which is
      # already on Rails' default allowlist.
      if Preview::Config.remote?
        args.push("-e", "PREVIEW_HOST=#{project.id}.preview.#{Preview::Config.domain}")
      end

      args.push(tag)

      result = @runner.run(*args, capture: true)
      raise RunError, result.stderr unless result.ok
      result.stdout.strip
    end

    def health_check!(project)
      deadline = Time.current + @health_timeout
      loop do
        return if curl_ok?(project)
        raise HealthcheckTimeout, "no /up after #{@health_timeout}s" if Time.current > deadline
        sleep @health_interval
      end
    end

    def curl_ok?(project)
      cmd =
        if Preview::Config.remote?
          # No host port mapping in prod — curl from inside the container.
          # The base image already includes curl in its apt install.
          ["docker", "exec", "preview-#{project.id}",
           "curl", "-fsS", "-o", "/dev/null", "-m", "2", "http://localhost:3000/up"]
        else
          ["curl", "-fsS", "-o", "/dev/null", "-m", "2",
           "http://localhost:#{project.preview_port}/up"]
        end

      @runner.run(*cmd, capture: true).ok
    end

    def register_with_proxy!(project)
      container_name = "preview-#{project.id}"
      ip = container_ip(container_name)
      raise "Could not resolve container IP for #{container_name}" if ip.blank?

      result = @runner.run(
        "docker", "exec", "kamal-proxy",
        "kamal-proxy", "deploy", "preview-#{project.id}",
        "--target", "#{ip}:3000",
        "--host", "#{project.id}.preview.#{Preview::Config.domain}",
        "--tls",
        capture: true
      )
      raise "kamal-proxy deploy failed: #{result.stderr}" unless result.ok
    end

    def container_ip(container_name)
      result = @runner.run(
        "docker", "inspect",
        "-f", "{{(index .NetworkSettings.Networks \"#{NETWORK}\").IPAddress}}",
        container_name,
        capture: true
      )
      return nil unless result.ok
      result.stdout.strip.presence
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
