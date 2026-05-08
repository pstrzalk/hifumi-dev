class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[github]

  has_one :profile, dependent: :destroy, inverse_of: :user, autosave: true
  accepts_nested_attributes_for :profile

  validates :profile, presence: true

  has_many :projects, dependent: :destroy
  has_one :github_connection, dependent: :destroy, inverse_of: :user
end
