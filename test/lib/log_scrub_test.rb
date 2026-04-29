require "test_helper"

class LogScrubTest < ActiveSupport::TestCase
  test "scrubs OpenRouter sk-or-* keys" do
    assert_equal "[FILTERED]", LogScrub.call("sk-or-abcdef1234567890XYZ")
    assert_equal "auth=[FILTERED] body", LogScrub.call("auth=sk-or-abcdef1234567890XYZ body")
  end

  test "scrubs Anthropic sk-ant-* keys" do
    assert_equal "[FILTERED]", LogScrub.call("sk-ant-abcdef1234567890XYZ")
  end

  test "passes through unrelated text unchanged" do
    msg = "request_id=abc message=hello world"
    assert_equal msg, LogScrub.call(msg)
  end

  test "handles nil and non-string inputs" do
    assert_equal "", LogScrub.call(nil)
    assert_equal "42", LogScrub.call(42)
  end

  test "scrubs every occurrence" do
    text = "first sk-or-AAAAAAAAAAAAAAAA then sk-or-BBBBBBBBBBBBBBBB"
    assert_equal "first [FILTERED] then [FILTERED]", LogScrub.call(text)
  end
end
