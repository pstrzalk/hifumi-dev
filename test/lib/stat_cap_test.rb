require "test_helper"
require Rails.root.join("lib/roast/stat_cap")

class StatCapTest < ActiveSupport::TestCase
  test "nil stat is returned unchanged" do
    assert_nil StatCap.call(nil)
  end

  test "empty stat is returned unchanged" do
    assert_equal "", StatCap.call("")
  end

  test "stat below threshold is returned unchanged" do
    stat = (1..30).map { |i| " file#{i}.rb | 1 +\n" }.join +
           " 30 files changed, 30 insertions(+)\n"
    assert_equal stat, StatCap.call(stat)
  end

  test "stat exactly at threshold is returned unchanged" do
    lines = (1..59).map { |i| " file#{i}.rb | 1 +\n" }.join
    summary = " 59 files changed, 59 insertions(+)\n"
    stat = lines + summary
    assert_equal 60, stat.lines.size
    assert_equal stat, StatCap.call(stat)
  end

  test "stat just above threshold is truncated, summary preserved" do
    lines = (1..60).map { |i| " file#{i}.rb | 1 +\n" }
    summary = " 60 files changed, 60 insertions(+)\n"
    stat = lines.join + summary

    result = StatCap.call(stat)

    assert_includes result, " file1.rb | 1 +\n"
    assert_includes result, " file50.rb | 1 +\n"
    assert_not_includes result, " file51.rb | 1 +\n"
    assert_includes result, "[... 10 more file(s) truncated ...]"
    assert result.end_with?(summary), "summary line must be preserved at the end"
  end

  test "pathological case (8,624 lines, vendor/bundle scenario)" do
    lines = (1..8623).map { |i| " path/to/file#{i}.rb | 1 +\n" }
    summary = " 8617 files changed, 1744492 insertions(+), 89 deletions(-)\n"
    stat = lines.join + summary

    result = StatCap.call(stat)

    assert_operator result.length, :<, 5_500, "capped output should stay well under 5KB"
    assert_includes result, "[... 8573 more file(s) truncated ...]"
    assert result.end_with?(summary)
    refute_includes result, " path/to/file51.rb | 1 +\n"
  end

  test "stat with no recognizable summary still returns last line as 'summary' (defensive)" do
    stat = (1..70).map { |i| "weird-line-#{i}\n" }.join

    result = StatCap.call(stat)

    assert_includes result, "weird-line-1\n"
    assert_includes result, "[... 19 more file(s) truncated ...]"
    assert result.end_with?("weird-line-70\n")
  end

  test "honors custom thresholds" do
    stat = (1..20).map { |i| " file#{i}.rb | 1 +\n" }.join +
           " 20 files changed, 20 insertions(+)\n"

    result = StatCap.call(stat, line_threshold: 10, head_lines: 5)

    assert_includes result, " file1.rb | 1 +\n"
    assert_includes result, " file5.rb | 1 +\n"
    refute_includes result, " file6.rb | 1 +\n"
    assert_includes result, "[... 15 more file(s) truncated ...]"
    assert result.end_with?(" 20 files changed, 20 insertions(+)\n")
  end

  test "misordered thresholds (head_lines >= line_threshold) returns input unchanged instead of producing garbage" do
    # Defensive: with head_lines: 50, line_threshold: 10 and 20 lines of input,
    # the naive truncation math would yield omitted = -31 and duplicate the
    # summary line. The guard short-circuits before that.
    stat = (1..20).map { |i| " file#{i}.rb | 1 +\n" }.join

    result = StatCap.call(stat, line_threshold: 10, head_lines: 50)

    assert_equal stat, result
  end
end
