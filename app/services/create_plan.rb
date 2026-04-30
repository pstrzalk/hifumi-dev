module CreatePlan
  Result = Struct.new(:instruction_description, :revisions, keyword_init: true)

  class << self
    def call(intent:, clarifications: {}, context: {}, openrouter_api_key:)
      implementation.call(
        intent: intent,
        clarifications: clarifications,
        context: context,
        openrouter_api_key: openrouter_api_key
      )
    end

    def implementation
      @implementation ||= AdHocLLM
    end

    attr_writer :implementation
  end
end
