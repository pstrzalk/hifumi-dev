class Project < ApplicationRecord
  belongs_to :user

  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true

  enum :preview_state, {
    stopped:  0,
    starting: 1,
    running:  2,
    failed:   3
  }, default: :stopped, prefix: :preview

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

  # Short natural-language summary of generation state, injected into the
  # GeneratorAgent's system prompt each turn. Read by the LLM to decide
  # whether it may call `start_generation` or must wait.
  def current_state_prompt
    active = instructions
      .where.not(phase: %w[completed failed cancelled])
      .order(:created_at).last
    return "No generation is currently running. You MAY call `start_generation` if the user wants to build or change something." unless active

    total = active.revisions.count
    done = active.revisions.where(status: :completed).count
    "A generation is CURRENTLY RUNNING (instruction ##{active.id}, #{done}/#{total} revisions complete). Do NOT call `start_generation` now. Do NOT claim any new work has been done — it hasn't. Tell the user you'll start new changes once the current build finishes."
  end

  # Generated Rails apps live OUTSIDE the generator's repo tree to avoid
  # `rails new`'s inside_application? walk-up check and to keep the two
  # filesystems (generator / generated apps) cleanly separated. Default is
  # a sibling of the generator repo; tests override via env var.
  def self.workspace_root
    ENV.fetch("RAILS_APP_GENERATOR_WORKSPACE_ROOT") do
      File.join(Dir.home, "projects", "rails-app-generator-workspaces")
    end
  end
end
