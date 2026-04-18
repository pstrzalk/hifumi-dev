class RemoveWorkspacePathFromProjects < ActiveRecord::Migration[8.1]
  def change
    remove_index :projects, :workspace_path
    remove_column :projects, :workspace_path, :string, null: false
  end
end
