module ModelSelectionsHelper
  # [label, id] pairs for a model select tag, in registry order.
  def model_select_options
    LLM::Stages::AVAILABLE_MODELS.map { |id, label| [ label, id ] }
  end
end
