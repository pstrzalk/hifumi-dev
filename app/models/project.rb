class Project < ApplicationRecord
  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true

  def workspace_path
    File.join(self.class.workspace_root, "project_#{id}")
  end

  def workspace_initialized?
    File.exist?(File.join(workspace_path, "Gemfile"))
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
