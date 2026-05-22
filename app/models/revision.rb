class Revision < ApplicationRecord
  # touch: true on :project only — a revision's status changes during a build
  # should bump "active … ago". Deliberately NOT on :instruction: that would
  # move Instruction.updated_at, and build_chat_events sorts terminal
  # instructions by updated_at (see project_phantom_status_rows_caveats).
  belongs_to :project, touch: true
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
