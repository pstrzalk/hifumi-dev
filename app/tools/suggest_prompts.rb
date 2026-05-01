class SuggestPrompts < RubyLLM::Tool
  def name = "suggest_prompts"
  description "Suggests 3-5 short next-step prompts the user can click to continue. Call after start_generation returns, or when offering the user a direction to take."

  params do
    array :prompts,
          of: :string,
          description: "Plain-language, short (<= 10 words), user-facing prompts."
  end

  def initialize(project:)
    super()
    @project = project
  end

  def execute(prompts:)
    if duplicate_in_turn?
      return {
        error: "suggest_prompts was already called this turn. Reply to the user with plain text and stop calling tools — calling the same tool twice in one turn corrupts the conversation history."
      }
    end

    sanitized = Array(prompts).map(&:to_s).map(&:strip).reject(&:empty?).first(5)
    broadcast_suggestions(sanitized)
    { prompts: sanitized }
  end

  private

  # RubyLLM persists the assistant message + its tool_call BEFORE dispatching
  # the tool, so by the time we run, our own tool_call row is already counted.
  # `count > 1` therefore means the LLM is calling us a second time within the
  # same user turn — which produces the illegal message ordering Anthropic
  # rejects on the next API call (assistant(use_X) → assistant(use_Y) →
  # user(result_X) → user(result_Y)). See diagnosis on project 15.
  def duplicate_in_turn?
    chat = @project.chat
    return false unless chat

    last_user_id = chat.messages.where(role: :user).order(:id).last&.id
    return false unless last_user_id

    ToolCall.joins(:message)
      .where(messages: { chat_id: chat.id })
      .where("messages.id > ?", last_user_id)
      .where(name: name)
      .count > 1
  end

  def broadcast_suggestions(prompts)
    Turbo::StreamsChannel.broadcast_replace_to(
      @project,
      target: "suggestions",
      partial: "suggestions/frame",
      locals: { prompts: prompts }
    )
  end
end
