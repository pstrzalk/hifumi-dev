class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :recoverable,
         :rememberable, :validatable

  has_one :profile, dependent: :destroy, inverse_of: :user, autosave: true
  accepts_nested_attributes_for :profile

  validates :profile, presence: true

  has_many :projects, dependent: :destroy
end
