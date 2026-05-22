class Message < ApplicationRecord
  # touch_chat: a new message bumps Chat.updated_at, which (Chat belongs_to
  # :project, touch: true) cascades to Project.updated_at — so "active … ago"
  # reflects chat activity. Streaming token writes use update_columns
  # (chat_respond_job.rb), which bypasses callbacks, so this fires once on
  # create and once on the message's final save, not per token.
  acts_as_message(touch_chat: true)
  has_many_attached :attachments

  after_create_commit :broadcast_append_message
  after_update_commit :broadcast_replace_message

  def visible_in_chat?
    return false if system_injected?
    return true if role == "user"
    role == "assistant" && (content.to_s.strip.present? || tool_calls.any?)
  end

  private

  def broadcast_append_message
    return unless %w[user assistant].include?(role)
    return if system_injected?

    broadcast_append_later_to chat.project,
      target: "messages",
      partial: "messages/message",
      locals: { message: self }
  end

  def broadcast_replace_message
    return if system_injected?

    broadcast_replace_later_to chat.project,
      target: ActionView::RecordIdentifier.dom_id(self),
      partial: "messages/message",
      locals: { message: self }
  end
end
