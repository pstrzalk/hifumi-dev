class Revision < ApplicationRecord
  belongs_to :project
  belongs_to :instruction
  belongs_to :parent, class_name: "Revision", optional: true

  enum :status, {
    pending: "pending",
    generating: "generating",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :position, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :summary, presence: true
  validates :prompt, presence: true
end
