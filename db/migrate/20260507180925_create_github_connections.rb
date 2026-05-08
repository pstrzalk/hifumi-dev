class CreateGithubConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :github_connections do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :provider,        null: false, default: "github_oauth"
      t.string :github_username, null: false
      t.bigint :github_user_id,  null: false
      t.string :access_token,    null: false
      t.string :refresh_token
      t.datetime :expires_at

      t.timestamps
    end

    add_index :github_connections, :github_user_id, unique: true
  end
end
