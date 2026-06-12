class Profile < ApplicationRecord
  belongs_to :user, inverse_of: :profile

  encrypts :openrouter_api_key

  validates :first_name, :last_name, :openrouter_api_key, presence: true
  validates(*LLM::Stages.profile_columns,
    inclusion: { in: LLM::Stages::AVAILABLE_MODELS.keys, message: "is not an available model" })

  # The owner's per-stage defaults, keyed by the Project column each one
  # seeds — `ProjectsController#create` merges these under any explicit
  # selection posted from the new-project form.
  def default_models_for_project
    LLM::Stages::ALL.to_h { |stage| [ stage.project_column, self[stage.profile_column] ] }
  end
end
