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
    agent.with_context(ctx)
    # with_model costs a Model lookup + chat save + project touch — only pay
    # it when the project's selection actually differs from the chat's model.
    agent.with_model(project.chat_model) unless agent.model_id == project.chat_model
    agent.complete do |chunk|
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
    # Surface as a transient banner, not an assistant Message. Reasons:
    # - RubyLLM's `cleanup_failed_messages` already destroyed the empty
    #   placeholder before re-raising; any "find latest assistant" fallback
    #   would clobber the prior turn's good reply.
    # - "auth failed", "out of credits" etc. are operator concerns, not
    #   conversational artifacts — they shouldn't pollute chat history.
    broadcast_chat_notice(project, friendly_message_for(e)) if project
  end

  private

  FRIENDLY_ERRORS = {
    "RubyLLM::UnauthorizedError"      => "OpenRouter rejected your API key. Update it in Account.",
    "RubyLLM::PaymentRequiredError"   => "Your OpenRouter account is out of credits. Top up at openrouter.ai/credits.",
    "RubyLLM::RateLimitError"         => "OpenRouter is rate-limiting requests. Try again in a moment.",
    "RubyLLM::OverloadedError"        => "OpenRouter is overloaded. Try again shortly.",
    "RubyLLM::ServerError"            => "OpenRouter returned a server error. Try again shortly.",
    "RubyLLM::ServiceUnavailableError" => "OpenRouter is temporarily unavailable. Try again shortly.",
    "RubyLLM::ContextLengthExceededError" => "This conversation is too long for the model. Start a new project.",
    "RubyLLM::ModelNotFoundError"     => "The configured model is unavailable. Contact the operator.",
    # The model returned 400 — almost always a structural problem with the
    # conversation history (e.g. tool_use without a matching tool_result).
    # Once written, the chat is unrecoverable; the user can only start over.
    "RubyLLM::BadRequestError"        => "This conversation can't be continued by the model. Please start a new project."
  }.freeze

  def friendly_message_for(exception)
    return "Add your OpenRouter API key in Account before sending messages." if exception.message.include?("has no OpenRouter API key")

    FRIENDLY_ERRORS[exception.class.name] ||
      "Something went wrong contacting the model. Please try again."
  end

  def broadcast_chat_notice(project, message)
    Turbo::StreamsChannel.broadcast_replace_to(
      project,
      target: "chat_notice",
      partial: "shared/chat_notice",
      locals: { message: message }
    )
  end

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
