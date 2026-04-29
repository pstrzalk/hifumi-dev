class ChatRespondJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    user_message = Message.find(message_id)
    chat = user_message.chat
    project = chat.project
    api_key = project.user.profile.openrouter_api_key
    raise "Project owner has no OpenRouter API key" if api_key.blank?

    ctx = RubyLLM.context do |c|
      c.openrouter_api_key = api_key
    end

    agent = GeneratorAgent.find(user_message.chat_id)
    agent.with_context(ctx).complete do |chunk|
      delta = chunk.content.to_s
      next if delta.empty?

      assistant = latest_streaming_assistant(chat)
      next if assistant.nil?

      assistant.update_columns(content: assistant.content.to_s + delta)
      broadcast_replace(project, assistant)
    end
  rescue StandardError => e
    Rails.logger.error("[ChatRespondJob] message_id=#{message_id} #{e.class}: #{LogScrub.call(e.message)}")
    Rails.logger.error(LogScrub.call(e.backtrace.first(20).join("\n"))) if e.backtrace
    # Append a fresh error bubble. RubyLLM's `cleanup_failed_messages`
    # already destroyed the empty assistant placeholder before re-raising,
    # so any "find latest assistant" fallback would either pick up a
    # successful PRIOR-turn reply (and overwrite it) or be nil. Creating
    # a new message is unambiguous; the Message model's after_create_commit
    # broadcasts the append.
    chat&.messages&.create!(role: :assistant, content: "Error: #{LogScrub.call(e.message)}")
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
