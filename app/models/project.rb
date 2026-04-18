class Project < ApplicationRecord
  has_one :chat, dependent: :destroy
  has_many :instructions, dependent: :destroy
  has_many :revisions, dependent: :destroy

  validates :name, presence: true
  validates :workspace_path, presence: true, uniqueness: true
end
