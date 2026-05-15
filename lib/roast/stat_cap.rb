# frozen_string_literal: true

# StatCap caps `git show --stat` output by line count while always preserving
# the trailing summary line ("N files changed, M insertions(+), K deletions(-)").
#
# Used by W2.6 update_docs to keep the prompt bounded when a single revision
# touches many files (e.g., an accidentally-committed vendor tree). The
# summary line is the most valuable single signal in a pathological case —
# without it, a model handed a truncated stat would have no idea that the
# revision was outside normal scale.
module StatCap
  DEFAULT_LINE_THRESHOLD = 60
  DEFAULT_HEAD_LINES = 50

  def self.call(stat, line_threshold: DEFAULT_LINE_THRESHOLD, head_lines: DEFAULT_HEAD_LINES)
    return stat if stat.nil? || stat.empty?

    lines = stat.lines
    # Two reasons to skip truncation: (1) input already fits the threshold,
    # (2) caller passed head_lines >= line_threshold, in which case truncation
    # would produce a duplicated summary line and a negative omitted count.
    # Trip the same early return — input shorter than head + summary can't
    # meaningfully be truncated anyway.
    return stat if lines.size <= line_threshold
    return stat if lines.size <= head_lines + 1

    summary = lines.last
    head = lines.first(head_lines).join
    omitted = lines.size - head_lines - 1
    "#{head}[... #{omitted} more file(s) truncated ...]\n#{summary}"
  end
end
