class Project < ApplicationRecord
  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true

  def workspace_path
    "storage/workspaces/project_#{id}"
  end

  def workspace_initialized?
    File.exist?(Rails.root.join(workspace_path, "Gemfile"))
  end
end
