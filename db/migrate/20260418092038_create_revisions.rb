class CreateRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :revisions do |t|
      t.references :project, null: false
      t.references :instruction, null: false
      t.references :parent
      t.string :git_sha
      t.text :summary, null: false
      t.integer :position, null: false
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    add_index :revisions, [ :instruction_id, :position ], unique: true

    add_foreign_key :revisions, :projects, on_delete: :cascade
    add_foreign_key :revisions, :instructions, on_delete: :cascade
    add_foreign_key :revisions, :revisions, column: :parent_id, on_delete: :nullify
  end
end
