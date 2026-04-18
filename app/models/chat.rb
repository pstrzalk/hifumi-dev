class Chat < ApplicationRecord
  acts_as_chat

  belongs_to :project
end
