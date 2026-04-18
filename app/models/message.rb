class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments

  after_create_commit :broadcast_append_message

  private

  def broadcast_append_message
    broadcast_append_later_to chat.project,
      target: "messages",
      partial: "messages/message",
      locals: { message: self }
  end
end
