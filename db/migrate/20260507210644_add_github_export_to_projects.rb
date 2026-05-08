class AddGithubExportToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :github_repo_full_name, :string
    add_column :projects, :export_state,          :integer, null: false, default: 0
    add_column :projects, :exported_at,           :datetime
    add_column :projects, :export_error,          :text

    add_index :projects, :github_repo_full_name, unique: true, where: "github_repo_full_name IS NOT NULL"
  end
end
