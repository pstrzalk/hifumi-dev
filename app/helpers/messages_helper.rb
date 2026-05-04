module MessagesHelper
  def message_row_class(message)
    return "hidden" unless message.visible_in_chat?
    base = "msg"
    base + (message.role == "user" ? " msg-user" : " msg-asst")
  end

  def render_as_pill?(message)
    message.role == "assistant" && message.content.to_s.strip.empty? && message.tool_calls.any?
  end

  def tool_call_pill_text(message)
    names = message.tool_calls.map(&:name).uniq
    case names
    when ["create_application"] then "starting generation…"
    when ["suggest_prompts"]  then "preparing suggestions…"
    else "running: #{names.join(", ")}"
    end
  end
end
