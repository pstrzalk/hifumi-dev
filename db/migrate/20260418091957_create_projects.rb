class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.string :workspace_path, null: false

      t.timestamps
    end
    add_index :projects, :workspace_path, unique: true
  end
end
