module MessagesHelper
  def message_row_class(message)
    return "hidden" unless message.visible_in_chat?
    message.role == "user" ? "flex justify-end" : "flex justify-start"
  end

  def render_as_pill?(message)
    message.role == "assistant" && message.content.to_s.strip.empty? && message.tool_calls.any?
  end

  def tool_call_pill_text(message)
    names = message.tool_calls.map(&:name).uniq
    case names
    when ["start_generation"] then "⚙ Starting generation…"
    when ["suggest_prompts"]  then "💡 Preparing suggestions…"
    else "⚙ Running: #{names.join(", ")}"
    end
  end
end
