class ToolCall < ApplicationRecord
  acts_as_tool_call

  # RubyLLM attaches tool_calls AFTER the parent message is saved, so the
  # message's own after_update_commit re-broadcasts before tool_calls exist.
  # Touch the parent here to trigger another replace once the call is persisted
  # — the re-render then sees message.tool_calls.any? and renders the pill.
  #
  # Skip on :destroy. RubyLLM's cleanup_failed_messages destroys the parent
  # message on API failure; the cascading ToolCall destroy would otherwise
  # try to touch an already-destroyed record and raise ActiveRecordError,
  # masking the original API error.
  after_commit :touch_message, on: [ :create, :update ]

  private

  def touch_message
    message&.touch
  end
end
