class AddStep4ColumnsToInstructionsAndRevisions < ActiveRecord::Migration[8.1]
  def change
    add_column :instructions, :user_intent, :text

    add_column :revisions, :prompt,       :text,     null: false, default: ""
    add_column :revisions, :started_at,   :datetime
    add_column :revisions, :finished_at,  :datetime
    add_column :revisions, :metrics,      :json,     default: {}, null: false
  end
end
