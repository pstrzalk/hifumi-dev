class Chat < ApplicationRecord
  acts_as_chat

  belongs_to :project

  # `acts_as_chat` (use_new_acts_as = true) delegates with_temperature /
  # with_thinking / with_params / with_headers / with_schema to to_llm but
  # not with_context — patch it in here, mirroring the same shape so the
  # AR record's chat lifecycle stays intact.
  def with_context(context)
    to_llm.with_context(context)
    self
  end
end
