class AddPreviewStateToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :preview_state,        :integer, null: false, default: 0
    add_column :projects, :preview_container_id, :string
    add_column :projects, :preview_started_at,   :datetime
    add_column :projects, :preview_error,        :text
  end
end
