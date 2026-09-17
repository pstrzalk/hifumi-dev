# RubyLLM resolves models against the ruby_llm_models table and falls back to
# the gem's bundled models.json only while that table is empty. Seed exactly
# what LLM::Stages offers, under the one provider hifumi talks to, so a fresh
# database resolves every offered id offline and never runs on the bundle.
# Bare rows are enough to resolve a chat; `RubyLLM.models.refresh` enriches
# them in place (matched on provider + model_id) when metadata is wanted.
# Idempotent — safe on a populated production store.
LLM::Stages::AVAILABLE_MODELS.each do |model_id, name|
  RubyLLM::ActiveRecord::Model.find_or_create_by!(model_id: model_id, provider: LLM::Stages::PROVIDER.to_s) do |model|
    model.name = name
  end
end
