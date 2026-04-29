module LogScrub
  PATTERNS = [
    /sk-or-[A-Za-z0-9_-]{16,}/,    # OpenRouter
    /sk-ant-[A-Za-z0-9_-]{16,}/    # Anthropic (defensive — shouldn't appear in prod)
  ].freeze

  module_function

  def call(text)
    str = text.to_s
    PATTERNS.each { |p| str = str.gsub(p, "[FILTERED]") }
    str
  end
end
