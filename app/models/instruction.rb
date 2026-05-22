class Instruction < ApplicationRecord
  belongs_to :project, touch: true
  belongs_to :anchor_message, class_name: "Message"
  has_many :revisions, dependent: :destroy

  # Phases past which an instruction does no more work. `cancelled` is
  # defined but currently unreachable (no code path writes it).
  TERMINAL_PHASES = %w[completed failed cancelled].freeze

  enum :phase, {
    researching: "researching",
    planning: "planning",
    implementing: "implementing",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }, validate: true

  validates :description, presence: true

  def terminal? = TERMINAL_PHASES.include?(phase)
end
