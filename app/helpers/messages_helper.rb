module MessagesHelper
  def tool_call_pill_text(message)
    names = message.tool_calls.map(&:name).uniq
    case names
    when ["start_generation"] then "⚙ Starting generation…"
    when ["suggest_prompts"]  then "💡 Preparing suggestions…"
    else "⚙ Running: #{names.join(", ")}"
    end
  end
end
