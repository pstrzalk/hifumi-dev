class Message < ApplicationRecord
  acts_as_message
  has_many_attached :attachments

  after_create_commit :broadcast_append_message
  after_update_commit :broadcast_replace_message

  def visible_in_chat?
    return true if role == "user"
    role == "assistant" && (content.to_s.strip.present? || tool_calls.any?)
  end

  private

  def broadcast_append_message
    return unless %w[user assistant].include?(role)

    broadcast_append_later_to chat.project,
      target: "messages",
      partial: "messages/message",
      locals: { message: self }
  end

  def broadcast_replace_message
    broadcast_replace_later_to chat.project,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "messages/message",
      locals: { message: self }
  end
end
