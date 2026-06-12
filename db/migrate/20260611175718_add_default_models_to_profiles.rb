class AddDefaultModelsToProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :profiles, :default_chat_model,              :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :profiles, :default_plan_creation_model,     :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :profiles, :default_plan_modification_model, :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :profiles, :default_template_model,          :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :profiles, :default_code_model,              :string, null: false, default: "anthropic/claude-sonnet-4.6"
    add_column :profiles, :default_docs_model,              :string, null: false, default: "anthropic/claude-haiku-4.5"
  end
end
