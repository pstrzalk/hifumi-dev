class CreateProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :profiles do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :first_name
      t.string :last_name
      t.string :openrouter_api_key

      t.timestamps
    end
  end
end
