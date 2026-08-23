# Class name deviates from `bin/rails generate ruby_llm:upgrade` output
# (AddRubyLlmV20Columns): this app declares `inflect.acronym "LLM"`, so Rails
# camelizes this filename to AddRubyLLMV20Columns and rejects the generated name.
class AddRubyLLMV20Columns < ActiveRecord::Migration[8.1]
  LEGACY_TOKEN_COLUMNS = %w[input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens].freeze
  LEGACY_COST_COLUMNS = %w[total_cost cost_details].freeze

  def up
    add_chat_and_message_columns
    move_models
    move_tool_calls
    move_batches
    create_usage_entries
    backfill_usage_entries
    remove_legacy_message_columns
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "RubyLLM v2 moves application-owned records into RubyLLM-owned tables"
  end

  private

  def add_chat_and_message_columns
    add_column :chats, :cancelled, :boolean, null: false, default: false unless column_exists?(:chats, :cancelled)

    add_column :messages, :citations, :json unless column_exists?(:messages, :citations)
    unless column_exists?(:messages, :server_tool_calls)
      add_column :messages, :server_tool_calls, :json
    end
    add_column :messages, :raw_content, :json unless column_exists?(:messages, :raw_content)
    add_column :messages, :raw_reasoning, :json unless column_exists?(:messages, :raw_reasoning)
    add_column :messages, :finish_reason, :string unless column_exists?(:messages, :finish_reason)
    unless column_exists?(:messages, :cache_until_here)
      add_column :messages, :cache_until_here, :boolean, null: false, default: false
    end
    if column_exists?(:messages, :cached_tokens) &&
       !column_exists?(:messages, :cache_read_tokens)
      rename_column :messages, :cached_tokens, :cache_read_tokens
    end
    if column_exists?(:messages, :cache_creation_tokens) &&
       !column_exists?(:messages, :cache_write_tokens)
      rename_column :messages, :cache_creation_tokens, :cache_write_tokens
    end
  end

  def move_models
    move_table(:models, :ruby_llm_models) { create_models }
    normalize_chat_model_reference(:chats, :model_id)
    replace_message_model_reference(:messages, :model_id)
  end

  def create_models
    create_table :ruby_llm_models do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff

      t.json :modalities, default: {}
      t.json :capabilities, default: []
      t.json :pricing, default: {}
      t.json :metadata, default: {}

      t.timestamps
      t.index [ :provider, :model_id ], unique: true
      t.index :provider
      t.index :family
    end
  end

  def normalize_chat_model_reference(table, legacy_column)
    return unless column_exists?(table, legacy_column)

    column = connection.columns(table).find { |candidate| candidate.name == legacy_column.to_s }
    model_primary_key = connection.primary_key(:ruby_llm_models)
    model_key_column = connection.columns(:ruby_llm_models).find { |candidate| candidate.name == model_primary_key }
    unless column.type == model_key_column.type
      raise "Expected #{table}.#{legacy_column} to match ruby_llm_models.#{model_primary_key}"
    end

    if legacy_column != :ruby_llm_model_id
      remove_foreign_key table, column: legacy_column if foreign_key_exists?(table, column: legacy_column)
      remove_index table, legacy_column if index_exists?(table, legacy_column)
      rename_column table, legacy_column, :ruby_llm_model_id
    end

    add_index table, :ruby_llm_model_id unless index_exists?(table, :ruby_llm_model_id)
    unless foreign_key_exists?(table, :ruby_llm_models, column: :ruby_llm_model_id)
      add_foreign_key table, :ruby_llm_models, column: :ruby_llm_model_id
    end
  end

  def replace_message_model_reference(table, legacy_column)
    return unless column_exists?(table, legacy_column)

    add_column table, :provider, :string unless column_exists?(table, :provider)
    column = connection.columns(table).find { |candidate| candidate.name == legacy_column.to_s }

    if column.type == :string
      rename_column table, legacy_column, :model_id if legacy_column != :model_id
      add_index table, [ :provider, :model_id ] unless index_exists?(table, [ :provider, :model_id ])
      return
    end

    add_column table, :ruby_llm_model_id, :string
    records = migration_record(table)
    migration_record(:ruby_llm_models).find_each do |model|
      records.where(legacy_column => model.id).update_all(
        ruby_llm_model_id: model.model_id,
        provider: model.provider
      )
    end

    remove_foreign_key table, column: legacy_column if foreign_key_exists?(table, column: legacy_column)
    remove_index table, legacy_column if index_exists?(table, legacy_column)
    remove_column table, legacy_column
    rename_column table, :ruby_llm_model_id, :model_id
    add_index table, [ :provider, :model_id ] unless index_exists?(table, [ :provider, :model_id ])
  end

  def move_tool_calls
    move_table(:tool_calls, :ruby_llm_tool_calls) { create_tool_calls }
    normalize_tool_calls
  end

  def create_tool_calls
    create_table :ruby_llm_tool_calls do |t|
      t.references :message, polymorphic: true, null: false, type: :bigint, index: false
      t.references :result, polymorphic: true, type: :bigint, index: false
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.string :approval

      t.json :arguments, default: {}

      t.timestamps
    end
  end

  def normalize_tool_calls
    table = :ruby_llm_tool_calls
    legacy_message_column = :message_id

    if legacy_message_column != :message_id && column_exists?(table, legacy_message_column)
      remove_foreign_key table, column: legacy_message_column if foreign_key_exists?(table, column: legacy_message_column)
      rename_column table, legacy_message_column, :message_id
    end
    remove_foreign_key table, column: :message_id if foreign_key_exists?(table, column: :message_id)

    add_column table, :message_type, :string unless column_exists?(table, :message_type)
    migration_record(table).where(message_type: nil).update_all(message_type: 'Message')
    change_column_null table, :message_type, false

    add_column table, :result_type, :string unless column_exists?(table, :result_type)
    add_column table, :result_id, :bigint unless column_exists?(table, :result_id)
    add_column table, :approval, :string unless column_exists?(table, :approval)
    backfill_tool_results

    add_index table, [ :message_type, :message_id ] unless index_exists?(table, [ :message_type, :message_id ])
    add_index table, [ :result_type, :result_id ] unless index_exists?(table, [ :result_type, :result_id ])
    deduplicate_tool_call_ids unless index_exists?(table, :tool_call_id)
    add_index table, :tool_call_id, unique: true unless index_exists?(table, :tool_call_id)
    add_index table, :name unless index_exists?(table, :name)
  end

  # Provider tool-call ids are only unique within one request, so legacy data
  # can repeat them across chats. The unique index needs them globally unique;
  # renamed rows keep their result links, which join by primary key.
  def deduplicate_tool_call_ids
    tool_calls = migration_record(:ruby_llm_tool_calls)
    duplicated = tool_calls.group(:tool_call_id).having("COUNT(*) > 1").pluck(:tool_call_id)
    duplicated.each do |tool_call_id|
      tool_calls.where(tool_call_id: tool_call_id).order(:id).offset(1).each do |record|
        record.update!(tool_call_id: "#{tool_call_id}-migrated-#{record.id}")
      end
    end
  end

  def backfill_tool_results
    result_column = :tool_call_id
    return unless column_exists?(:messages, result_column)

    messages = migration_record(:messages)
    tool_calls = migration_record(:ruby_llm_tool_calls)
    messages.where.not(result_column => nil).pluck(messages.primary_key, result_column).each do |message_id, tool_call_id|
      tool_calls.where(tool_calls.primary_key => tool_call_id).update_all(
        result_id: message_id,
        result_type: 'Message'
      )
    end

    remove_foreign_key :messages, column: result_column if foreign_key_exists?(:messages, column: result_column)
    remove_index :messages, result_column if index_exists?(:messages, result_column)
    remove_column :messages, result_column
  end

  def move_batches
    move_table(:batches, :ruby_llm_batches) { create_batches }
    add_column :ruby_llm_batches, :chat_type, :string unless column_exists?(:ruby_llm_batches, :chat_type)
    add_column :ruby_llm_batches, :batch_protocol, :string unless column_exists?(:ruby_llm_batches, :batch_protocol)
    add_column :ruby_llm_batches, :request_counts, :json unless column_exists?(:ruby_llm_batches, :request_counts)
    migration_record(:ruby_llm_batches).where(chat_type: nil).update_all(chat_type: 'Chat')
    add_index :ruby_llm_batches, [ :provider, :provider_batch_id ], unique: true unless index_exists?(:ruby_llm_batches, [ :provider, :provider_batch_id ])
    add_index :ruby_llm_batches, :status unless index_exists?(:ruby_llm_batches, :status)
  end

  def create_batches
    create_table :ruby_llm_batches do |t|
      t.string :provider_batch_id, null: false
      t.string :provider, null: false
      t.string :status
      t.boolean :completed, null: false, default: false
      t.string :chat_type
      t.string :batch_protocol

      t.json :chat_ids, default: []

      t.json :request_counts
      t.timestamps
    end
  end

  def create_usage_entries
    return if table_exists?(:ruby_llm_usages)

    create_table :ruby_llm_usages do |t|
      t.references :chat, polymorphic: true, null: false, type: :bigint, index: false
      t.references :message, polymorphic: true, type: :bigint, index: false
      t.string :operation, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens
      t.decimal :input_cost, precision: 16, scale: 10
      t.decimal :output_cost, precision: 16, scale: 10
      t.decimal :cache_read_cost, precision: 16, scale: 10
      t.decimal :cache_write_cost, precision: 16, scale: 10
      t.decimal :thinking_cost, precision: 16, scale: 10
      t.decimal :total_cost, precision: 16, scale: 10
      t.timestamps
      t.index [ :chat_type, :chat_id ]
      t.index [ :message_type, :message_id ]
      t.index :status
      t.check_constraint "operation IN ('chat', 'embedding', 'moderation', 'image', 'speech', 'transcription', 'ocr', 'rerank')"
      t.check_constraint "status IN ('pending', 'succeeded', 'failed', 'cancelled')"
    end
  end

  def backfill_usage_entries
    present = LEGACY_TOKEN_COLUMNS.select { |column| column_exists?(:messages, column) }
    return if present.empty?

    entries = migration_record(:ruby_llm_usages)
    condition = present.map { |column| "#{column} IS NOT NULL" }.join(' OR ')
    migration_record(:messages).where(condition).find_each do |message|
      provider, model = message_model_identity(message)
      next unless provider && model

      entries.create!(legacy_usage_attributes(message, provider:, model:))
    end
  end

  def message_model_identity(message)
    identity = [ message['provider'], message['model_id'] ]
    return identity if identity.all?

    model_identities[chat_model_ids[message['chat_id']]]
  end

  def model_identities
    @model_identities ||= migration_record(:ruby_llm_models).all.to_h do |model|
      [ model.id, [ model['provider'], model['model_id'] ] ]
    end
  end

  def chat_model_ids
    @chat_model_ids ||= if column_exists?(:chats, :ruby_llm_model_id)
      migration_record(:chats).pluck(:id, :ruby_llm_model_id).to_h
    else
      {}
    end
  end

  def legacy_usage_attributes(message, provider:, model:)
    details = message['cost_details']
    details = JSON.parse(details) if details.is_a?(String)
    details ||= {}
    {
      chat_type: 'Chat',
      chat_id: message['chat_id'],
      message_type: 'Message',
      message_id: message.id,
      operation: 'chat',
      provider: provider,
      model: model,
      status: 'succeeded',
      input_tokens: message['input_tokens'],
      output_tokens: message['output_tokens'],
      cache_read_tokens: message['cache_read_tokens'],
      cache_write_tokens: message['cache_write_tokens'],
      thinking_tokens: message['thinking_tokens'],
      input_cost: details['input'],
      output_cost: details['output'],
      cache_read_cost: details['cache_read'],
      cache_write_cost: details['cache_write'],
      thinking_cost: details['thinking'],
      total_cost: message['total_cost'] || details['total'],
      created_at: message['created_at'],
      updated_at: message['updated_at']
    }
  end

  def remove_legacy_message_columns
    (LEGACY_TOKEN_COLUMNS + LEGACY_COST_COLUMNS).each do |column|
      remove_column :messages, column if column_exists?(:messages, column)
    end
  end

  def move_table(source, target)
    if source != target && table_exists?(source)
      if table_exists?(target)
        raise "Both #{source} and #{target} exist. Merge or remove one before running this migration."
      end
      rename_table source, target
    elsif !table_exists?(target)
      yield
    end
  end

  def migration_record(table)
    Class.new(ActiveRecord::Base) do
      self.table_name = table.to_s
      self.inheritance_column = :_type_disabled
    end
  end
end
