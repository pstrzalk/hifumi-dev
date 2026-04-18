class CreateInstructions < ActiveRecord::Migration[8.1]
  def change
    create_table :instructions do |t|
      t.references :project, null: false
      t.references :anchor_message, null: false
      t.string :phase, null: false, default: "researching"
      t.text :description, null: false
      t.text :research_output

      t.timestamps
    end

    add_foreign_key :instructions, :projects, on_delete: :cascade
    add_foreign_key :instructions, :messages, column: :anchor_message_id, on_delete: :cascade
  end
end
