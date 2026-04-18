module CreatePlan
  Result = Struct.new(:instruction_description, :revisions, keyword_init: true)

  class << self
    def call(intent:, clarifications: {}, context: {})
      implementation.call(intent: intent, clarifications: clarifications, context: context)
    end

    def implementation
      @implementation ||= AdHocLLM
    end

    attr_writer :implementation
  end
end
