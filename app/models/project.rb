class Project < ApplicationRecord
  belongs_to :user

  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true
  validates(*LLM::Stages.project_columns,
    inclusion: { in: LLM::Stages::AVAILABLE_MODELS.keys, message: "is not an available model" })

  # Identity used for every commit made into a generated workspace —
  # written to repo-local .git/config at init time + applied as -c flags
  # on every explicit-author commit. Set on commit, not on push: GitHub
  # attributes commits by author email regardless of who pushed them.
  COMMIT_AUTHOR_NAME  = "hifumi.dev"
  COMMIT_AUTHOR_EMAIL = "code@hifumi.dev"

  enum :preview_state, {
    stopped:  0,
    starting: 1,
    running:  2,
    failed:   3
  }, default: :stopped, prefix: :preview

  enum :export_state, {
    not_exported: 0,
    exporting:    1,
    exported:     2,
    failed:       3
  }, default: :not_exported, prefix: :export

  def github_repo_url
    return nil if github_repo_full_name.blank?
    "https://github.com/#{github_repo_full_name}"
  end

  def exportable?
    user.github_connection&.connected? &&
      instructions.where(phase: :completed).exists? &&
      !export_exporting?
  end

  def workspace_path
    File.join(self.class.workspace_root, "project_#{id}")
  end

  # Preview HTTP endpoint — derived from id, only meaningful while running
  # (per memory feedback_derive_dont_store: don't store what's a pure
  # function of another column).
  def preview_url
    return nil unless preview_running?

    if Preview::Config.remote?
      "https://#{id}.preview.#{Preview::Config.domain}"
    else
      "http://localhost:#{preview_port}"
    end
  end

  def preview_port
    Preview::Config.port_offset + id
  end

  def workspace_initialized?
    File.exist?(File.join(workspace_path, "Gemfile"))
  end

  # Derived, read-time project build state — the basis of the dashboard
  # breakdown, the projects-list card tag, and the project-page header tag.
  # Builds run strictly one at a time (the create/modify tool refuses a
  # second while one is active), so the latest instruction's phase IS the
  # project's build state — no scanning needed.
  #   no instructions     → :new
  #   latest not terminal → :generating
  #   latest completed    → :ready
  #   latest failed       → :failed   (also cancelled — unreachable today)
  #
  # Ordering by [created_at, id]: id breaks created_at ties deterministically
  # so the dashboard counts are stable. Uses the in-memory `instructions`
  # association — eager-load it (`includes(:instructions)`) wherever
  # build_state is called in bulk; HomeController#load_dashboard and
  # ProjectsController#index do.
  def build_state
    latest = instructions.max_by { |i| [ i.created_at, i.id ] }
    return :new unless latest
    return :generating unless latest.terminal?

    latest.completed? ? :ready : :failed
  end

  # Short natural-language summary of generation state, injected into the
  # GeneratorAgent's system prompt each turn. Selects between STATE A (no
  # build running) and STATE B (build running) — the prompt's lettered sections.
  def current_state_prompt
    active = instructions
      .where.not(phase: %w[completed failed cancelled])
      .order(:created_at).last
    return "STATE A — No generation is currently running. You may guide the user toward a build/change, but only call `create_application`/`modify_application` AFTER the user explicitly confirms in their next message." unless active

    total = active.revisions.count
    done = active.revisions.where(status: :completed).count
    "STATE B — A generation is CURRENTLY RUNNING (instruction ##{active.id}, #{done}/#{total} revisions complete). Do NOT call `create_application` or `modify_application`. Do NOT claim any new work has been done — it hasn't. Tell the user you'll start their next change once the current build finishes."
  end

  # Generated Rails apps live OUTSIDE the generator's repo tree to avoid
  # `rails new`'s inside_application? walk-up check and to keep the two
  # filesystems (generator / generated apps) cleanly separated. Default is
  # a sibling of the generator repo; tests override via env var.
  def self.workspace_root
    ENV.fetch("HIFUMI_DEV_WORKSPACE_ROOT") do
      File.join(Dir.home, "projects", "hifumi-dev-workspaces")
    end
  end
end
