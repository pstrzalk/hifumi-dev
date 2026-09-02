module MessagesHelper
  def message_row_class(message)
    return "hidden" unless message.visible_in_chat?
    base = "msg"
    base + (message.role == "user" ? " msg-user" : " msg-asst")
  end

  def tool_call_pill_text(message)
    # v2: message.tool_calls is a Hash keyed by provider tool-call id, whose
    # values are RubyLLM::ToolCall. The persisted rows are ruby_llm_tool_calls.
    calls = message.tool_calls.values
    call = calls.first
    case call&.name
    when "create_application", "modify_application"
      intent = call.arguments["intent"].to_s
      intent.empty? ? "🌀 Build started" : "🌀 Build started: #{intent}"
    else
      "running: #{calls.map(&:name).uniq.join(", ")}"
    end
  end

  # Assistant replies render as markdown once the stream has finished; user text and
  # mid-stream text stay plain. Returns an html_safe fragment in the formatted case
  # and a plain String otherwise, so the view's <%= %> escapes it.
  def message_body_html(message, streaming: false)
    return message.content.to_s unless format_message_body?(message, streaming)

    Markdown.render(message.content)
  end

  def message_body_class(message, streaming: false)
    format_message_body?(message, streaming) ? "msg-body msg-prose" : "msg-body"
  end

  private

  def format_message_body?(message, streaming)
    !streaming && message.role == "assistant"
  end
end
