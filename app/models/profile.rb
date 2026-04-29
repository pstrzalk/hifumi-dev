class Profile < ApplicationRecord
  belongs_to :user, inverse_of: :profile

  encrypts :openrouter_api_key

  validates :first_name, :last_name, :openrouter_api_key, presence: true
end
