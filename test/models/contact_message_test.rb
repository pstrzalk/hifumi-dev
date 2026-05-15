require "test_helper"

class ContactMessageTest < ActiveSupport::TestCase
  test "valid with email and message" do
    cm = ContactMessage.new(email: "a@b.co", message: "Hello there, this is a test.")
    assert cm.valid?
  end

  test "invalid without email" do
    cm = ContactMessage.new(message: "Hello there, this is a test.")
    refute cm.valid?
    assert_includes cm.errors[:email], "can't be blank"
  end

  test "invalid with malformed email" do
    cm = ContactMessage.new(email: "not-an-email", message: "Hello there, this is a test.")
    refute cm.valid?
  end

  test "invalid without message" do
    cm = ContactMessage.new(email: "a@b.co")
    refute cm.valid?
  end

  test "invalid with message shorter than 10 chars" do
    cm = ContactMessage.new(email: "a@b.co", message: "short")
    refute cm.valid?
  end

  test "invalid with message longer than 5000 chars" do
    cm = ContactMessage.new(email: "a@b.co", message: "x" * 5001)
    refute cm.valid?
  end
end
