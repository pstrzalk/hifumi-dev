class Instruction < ApplicationRecord
  belongs_to :project
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions, dependent: :destroy

  enum :phase, {
    researching: "researching",
    planning: "planning",
    implementing: "implementing",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  validates :description, presence: true
end
