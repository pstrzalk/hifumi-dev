class AddSystemInjectedToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :system_injected, :boolean, default: false, null: false
  end
end
