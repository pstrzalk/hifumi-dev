class ChatRespondJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    user_message = Message.find(message_id)
    chat = user_message.chat
    assistant = nil

    chat.complete do |chunk|
      delta = chunk.content.to_s
      next if delta.empty?

      assistant ||= latest_assistant(chat)
      assistant.update_columns(content: assistant.content.to_s + delta)
      broadcast_replace(chat.project, assistant)
    end
  rescue StandardError => e
    # TODO(Step 6): typed error event + proper UX
    assistant ||= latest_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
    assistant.update!(content: "Error: #{e.message}")
    broadcast_replace(chat.project, assistant)
  end

  private

  def latest_assistant(chat)
    chat.messages.where(role: :assistant).order(:id).last
  end

  def broadcast_replace(project, message)
    Turbo::StreamsChannel.broadcast_replace_to(
      project,
      target: ActionView::RecordIdentifier.dom_id(message),
      partial: "messages/message",
      locals: { message: message }
    )
  end
end
