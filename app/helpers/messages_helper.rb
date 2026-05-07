module MessagesHelper
  def message_row_class(message)
    return "hidden" unless message.visible_in_chat?
    base = "msg"
    base + (message.role == "user" ? " msg-user" : " msg-asst")
  end

  def tool_call_pill_text(message)
    call = message.tool_calls.first
    case call&.name
    when "create_application", "modify_application"
      intent = call.arguments["intent"].to_s
      intent.empty? ? "🌀 Build started" : "🌀 Build started: #{intent}"
    else
      "running: #{message.tool_calls.map(&:name).uniq.join(", ")}"
    end
  end
end
