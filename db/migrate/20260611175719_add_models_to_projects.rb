class AddModelsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :chat_model,              :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :projects, :plan_creation_model,     :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :projects, :plan_modification_model, :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :projects, :template_model,          :string, null: false, default: "anthropic/claude-haiku-4.5"
    add_column :projects, :code_model,              :string, null: false, default: "anthropic/claude-sonnet-4.6"
    add_column :projects, :docs_model,              :string, null: false, default: "anthropic/claude-haiku-4.5"
  end
end
