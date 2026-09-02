# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_22_224622) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "chats", force: :cascade do |t|
    t.boolean "cancelled", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "project_id", null: false
    t.integer "ruby_llm_model_id"
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_chats_on_project_id"
    t.index ["ruby_llm_model_id"], name: "index_chats_on_ruby_llm_model_id"
  end

  create_table "contact_messages", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.text "message", null: false
    t.datetime "updated_at", null: false
  end

  create_table "github_connections", force: :cascade do |t|
    t.string "access_token", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.bigint "github_user_id", null: false
    t.string "github_username", null: false
    t.string "provider", default: "github_oauth", null: false
    t.string "refresh_token"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["github_user_id"], name: "index_github_connections_on_github_user_id", unique: true
    t.index ["user_id"], name: "index_github_connections_on_user_id", unique: true
  end

  create_table "instructions", force: :cascade do |t|
    t.integer "anchor_message_id", null: false
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.string "phase", default: "researching", null: false
    t.integer "project_id", null: false
    t.text "research_output"
    t.datetime "updated_at", null: false
    t.text "user_intent"
    t.index ["anchor_message_id"], name: "index_instructions_on_anchor_message_id"
    t.index ["project_id"], name: "index_instructions_on_project_id"
  end

  create_table "messages", force: :cascade do |t|
    t.boolean "cache_until_here", default: false, null: false
    t.integer "chat_id", null: false
    t.json "citations"
    t.text "content"
    t.json "content_raw"
    t.datetime "created_at", null: false
    t.string "finish_reason"
    t.string "model_id"
    t.string "provider"
    t.json "raw_content"
    t.json "raw_reasoning"
    t.string "role", null: false
    t.json "server_tool_calls"
    t.boolean "system_injected", default: false, null: false
    t.text "thinking_signature"
    t.text "thinking_text"
    t.datetime "updated_at", null: false
    t.index ["chat_id"], name: "index_messages_on_chat_id"
    t.index ["provider", "model_id"], name: "index_messages_on_provider_and_model_id"
    t.index ["role"], name: "index_messages_on_role"
  end

  create_table "profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_chat_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "default_code_model", default: "anthropic/claude-sonnet-4.6", null: false
    t.string "default_docs_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "default_plan_creation_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "default_plan_modification_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "default_template_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "openrouter_api_key"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
  end

  create_table "projects", force: :cascade do |t|
    t.string "chat_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "code_model", default: "anthropic/claude-sonnet-4.6", null: false
    t.datetime "created_at", null: false
    t.string "docs_model", default: "anthropic/claude-haiku-4.5", null: false
    t.text "export_error"
    t.integer "export_state", default: 0, null: false
    t.datetime "exported_at"
    t.string "github_repo_full_name"
    t.string "name", null: false
    t.string "plan_creation_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "plan_modification_model", default: "anthropic/claude-haiku-4.5", null: false
    t.string "preview_container_id"
    t.text "preview_error"
    t.datetime "preview_started_at"
    t.integer "preview_state", default: 0, null: false
    t.string "template_model", default: "anthropic/claude-haiku-4.5", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["github_repo_full_name"], name: "index_projects_on_github_repo_full_name", unique: true, where: "github_repo_full_name IS NOT NULL"
    t.index ["user_id"], name: "index_projects_on_user_id"
  end

  create_table "revisions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "git_sha"
    t.integer "instruction_id", null: false
    t.json "metrics", default: {}, null: false
    t.integer "parent_id"
    t.integer "position", null: false
    t.integer "project_id", null: false
    t.text "prompt", default: "", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["instruction_id", "position"], name: "index_revisions_on_instruction_id_and_position", unique: true
    t.index ["instruction_id"], name: "index_revisions_on_instruction_id"
    t.index ["parent_id"], name: "index_revisions_on_parent_id"
    t.index ["project_id"], name: "index_revisions_on_project_id"
  end

  create_table "ruby_llm_batches", force: :cascade do |t|
    t.string "batch_protocol"
    t.json "chat_ids", default: []
    t.string "chat_type"
    t.boolean "completed", default: false, null: false
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.string "provider_batch_id", null: false
    t.json "request_counts"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["provider", "provider_batch_id"], name: "index_ruby_llm_batches_on_provider_and_provider_batch_id", unique: true
    t.index ["status"], name: "index_ruby_llm_batches_on_status"
  end

  create_table "ruby_llm_models", force: :cascade do |t|
    t.json "capabilities", default: []
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "family"
    t.date "knowledge_cutoff"
    t.integer "max_output_tokens"
    t.json "metadata", default: {}
    t.json "modalities", default: {}
    t.datetime "model_created_at"
    t.string "model_id", null: false
    t.string "name", null: false
    t.json "pricing", default: {}
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["family"], name: "index_ruby_llm_models_on_family"
    t.index ["provider", "model_id"], name: "index_ruby_llm_models_on_provider_and_model_id", unique: true
    t.index ["provider"], name: "index_ruby_llm_models_on_provider"
  end

  create_table "ruby_llm_tool_calls", force: :cascade do |t|
    t.string "approval"
    t.json "arguments", default: {}
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.string "message_type", null: false
    t.string "name", null: false
    t.bigint "result_id"
    t.string "result_type"
    t.text "thought_signature"
    t.string "tool_call_id", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_ruby_llm_tool_calls_on_message_id"
    t.index ["message_type", "message_id"], name: "index_ruby_llm_tool_calls_on_message_type_and_message_id"
    t.index ["name"], name: "index_ruby_llm_tool_calls_on_name"
    t.index ["result_type", "result_id"], name: "index_ruby_llm_tool_calls_on_result_type_and_result_id"
    t.index ["tool_call_id"], name: "index_ruby_llm_tool_calls_on_tool_call_id", unique: true
  end

  create_table "ruby_llm_usages", force: :cascade do |t|
    t.decimal "cache_read_cost", precision: 16, scale: 10
    t.integer "cache_read_tokens"
    t.decimal "cache_write_cost", precision: 16, scale: 10
    t.integer "cache_write_tokens"
    t.bigint "chat_id", null: false
    t.string "chat_type", null: false
    t.datetime "created_at", null: false
    t.decimal "input_cost", precision: 16, scale: 10
    t.integer "input_tokens"
    t.bigint "message_id"
    t.string "message_type"
    t.string "model", null: false
    t.string "operation", null: false
    t.decimal "output_cost", precision: 16, scale: 10
    t.integer "output_tokens"
    t.string "provider", null: false
    t.string "status", null: false
    t.decimal "thinking_cost", precision: 16, scale: 10
    t.integer "thinking_tokens"
    t.decimal "total_cost", precision: 16, scale: 10
    t.datetime "updated_at", null: false
    t.index ["chat_type", "chat_id"], name: "index_ruby_llm_usages_on_chat_type_and_chat_id"
    t.index ["message_type", "message_id"], name: "index_ruby_llm_usages_on_message_type_and_message_id"
    t.index ["status"], name: "index_ruby_llm_usages_on_status"
    t.check_constraint "operation IN ('chat', 'embedding', 'moderation', 'image', 'speech', 'transcription', 'ocr', 'rerank')"
    t.check_constraint "status IN ('pending', 'succeeded', 'failed', 'cancelled')"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "chats", "projects", on_delete: :cascade
  add_foreign_key "chats", "ruby_llm_models"
  add_foreign_key "github_connections", "users"
  add_foreign_key "instructions", "messages", column: "anchor_message_id", on_delete: :cascade
  add_foreign_key "instructions", "projects", on_delete: :cascade
  add_foreign_key "messages", "chats"
  add_foreign_key "profiles", "users"
  add_foreign_key "projects", "users"
  add_foreign_key "revisions", "instructions", on_delete: :cascade
  add_foreign_key "revisions", "projects", on_delete: :cascade
  add_foreign_key "revisions", "revisions", column: "parent_id", on_delete: :nullify
end
