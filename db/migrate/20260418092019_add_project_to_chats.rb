class AddProjectToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :project, null: false
    add_foreign_key :chats, :projects, on_delete: :cascade
  end
end
