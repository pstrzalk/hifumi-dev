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
    sanitized = Array(prompts).map(&:to_s).map(&:strip).reject(&:empty?).first(5)
    broadcast_suggestions(sanitized)
    { prompts: sanitized }
  end

  private

  def broadcast_suggestions(prompts)
    Turbo::StreamsChannel.broadcast_replace_to(
      @project,
      target: "suggestions",
      partial: "suggestions/frame",
      locals: { prompts: prompts }
    )
  end
end
