class Project < ApplicationRecord
  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true

  def workspace_path
    "storage/workspaces/#{id}"
  end
end
