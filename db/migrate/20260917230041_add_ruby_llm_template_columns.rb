# Brings the four RubyLLM-owned tables to the shape of ruby_llm 2.0.0.rc3's
# install templates. This schema came from an earlier 2.0 preview
# (20260822224622); upstream's `ruby_llm:upgrade` generator targets 1.16
# schemas and its validate_upgrade raises on this one, so — as its upgrade
# guide instructs for earlier previews — this is an application migration in
# the generator's own `unless column_exists?` idiom.
#
# Only unlisted_at is read on the paths hifumi exercises (Model.read raises
# UnknownAttributeError without it and silently falls back to the bundled
# registry). The other three are what the templates define and what the gem
# would write the first time a provider-executed tool call or a batch appears.
#
# Class name: this app declares `inflect.acronym "LLM"`, so the filename
# camelizes to AddRubyLLMTemplateColumns (as 20260822224622 did).
class AddRubyLLMTemplateColumns < ActiveRecord::Migration[8.1]
  # Explicit up/down rather than `change`: on revert, `change` re-evaluates
  # the `unless column_exists?` guards against the migrated schema, sees the
  # columns, skips every add_column and so records nothing to remove -- the
  # version reverts and the columns stay (observed 2026-09-18).
  def up
    add_column :ruby_llm_models, :unlisted_at, :datetime unless column_exists?(:ruby_llm_models, :unlisted_at)
    unless column_exists?(:ruby_llm_tool_calls, :remote)
      add_column :ruby_llm_tool_calls, :remote, :boolean, default: false, null: false
    end
    add_column :ruby_llm_batches, :raw_status, :string unless column_exists?(:ruby_llm_batches, :raw_status)
    add_column :ruby_llm_batches, :reported_cost, :json unless column_exists?(:ruby_llm_batches, :reported_cost)
  end

  def down
    remove_column :ruby_llm_batches, :reported_cost if column_exists?(:ruby_llm_batches, :reported_cost)
    remove_column :ruby_llm_batches, :raw_status if column_exists?(:ruby_llm_batches, :raw_status)
    remove_column :ruby_llm_tool_calls, :remote if column_exists?(:ruby_llm_tool_calls, :remote)
    remove_column :ruby_llm_models, :unlisted_at if column_exists?(:ruby_llm_models, :unlisted_at)
  end
end
