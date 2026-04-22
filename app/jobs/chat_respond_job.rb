class ChatRespondJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    user_message = Message.find(message_id)
    chat = user_message.chat
    project = chat.project
    agent = GeneratorAgent.find(user_message.chat_id)

    agent.complete do |chunk|
      delta = chunk.content.to_s
      next if delta.empty?

      assistant = latest_streaming_assistant(chat)
      next if assistant.nil?

      assistant.update_columns(content: assistant.content.to_s + delta)
      broadcast_replace(project, assistant)
    end
  rescue StandardError => e
    # TODO(Step 6): typed error event + proper UX
    Rails.logger.error(e.full_message)
    target = latest_streaming_assistant(chat) || chat.messages.create!(role: :assistant, content: "")
    target.update!(content: "Error: #{e.message}")
    broadcast_replace(project, target)
  end

  private

  def latest_streaming_assistant(chat)
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
