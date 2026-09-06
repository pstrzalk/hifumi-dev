# frozen_string_literal: true

require "json"

# Parses the [HIFUMI:VERIFY] sentinel lines VerifyRevision emits on the roast
# subprocess's stdout. Lives in lib/roast (excluded from autoload) because both
# sides need it: the workflow, which runs unbundled outside Rails, and
# ExecuteInstructionJob, which requires it explicitly.
module VerifyReport
  PREFIX = "[HIFUMI:VERIFY]"

  # Returns the record, or nil for any line that is not a well-shaped sentinel.
  #
  # The prefix is looked for anywhere in the line, not at column 0: Roast
  # captures everything a cog prints (STDOUT.puts included) and relays it
  # through its own logger, on stderr, as
  #   I, [2026-09-06T23:39:41.814076]  INFO -- ruby(:verify) ❯ [HIFUMI:VERIFY] {...}
  # (probed against roast-ai 1.1.0; a 25k-char line arrives intact).
  #
  # Shape is validated rather than presence-checked: agent output is arbitrary
  # and may contain the prefix by coincidence, and a malformed record must not
  # reach the database or raise inside the log-streaming thread.
  def self.parse_line(line)
    text = line.to_s
    start = text.index(PREFIX)
    return nil unless start

    record = JSON.parse(text[(start + PREFIX.length)..].strip)
    return nil unless record.is_a?(Hash)
    return nil unless record["stage"].is_a?(String)
    return nil unless record["checks"].is_a?(Array)
    return nil unless record["checks"].all? { |c| c.is_a?(Hash) && c["name"].is_a?(String) && [ true, false ].include?(c["passed"]) }

    record
  rescue JSON::ParserError
    nil
  end
end
