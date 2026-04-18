require "test_helper"

class ChatTest < ActiveSupport::TestCase
  test "belongs to a project" do
    assert_equal projects(:flowers), chats(:flowers).project
  end

  test "requires a project" do
    chat = Chat.new
    assert_not chat.valid?
    assert_includes chat.errors[:project], "must exist"
  end
end
