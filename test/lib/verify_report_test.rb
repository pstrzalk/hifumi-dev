require "test_helper"
require Rails.root.join("lib/roast/verify_report")

# VerifyReport.parse_line runs inside ExecuteInstructionJob's log-streaming
# thread on arbitrary subprocess output, so every rejection branch is pinned:
# it must return nil, never raise, for anything that is not a sentinel.
class VerifyReportTest < ActiveSupport::TestCase
  PREFIX = VerifyReport::PREFIX

  test "parses a well-formed sentinel" do
    line = %(#{PREFIX} {"stage":"W2.4","attempt":1,"checks":[{"check":"bundle_check","name":"bundle check","passed":true,"advisory":false,"ms":170}]})

    record = VerifyReport.parse_line(line)

    assert_equal "W2.4", record["stage"]
    assert_equal 1, record["attempt"]
    assert_equal [ { "check" => "bundle_check", "name" => "bundle check", "passed" => true, "advisory" => false, "ms" => 170 } ], record["checks"]
  end

  test "parses a sentinel line that still carries its trailing newline" do
    line = %(#{PREFIX} {"stage":"W2.B","checks":[]}\n)
    assert_equal({ "stage" => "W2.B", "checks" => [] }, VerifyReport.parse_line(line))
  end

  test "parses the sentinel out of Roast's log decoration (cog stdout is relayed on stderr as 'I, [ts]  INFO -- ruby(:verify) ❯ …')" do
    line = %(I, [2026-09-06T23:39:41.814076]  INFO -- ruby(:verify) ❯ #{PREFIX} {"stage":"W2.4","checks":[]})
    assert_equal({ "stage" => "W2.4", "checks" => [] }, VerifyReport.parse_line(line))
  end

  test "returns nil for a line without the prefix" do
    assert_nil VerifyReport.parse_line(%([W2.4] PASS bundle check))
    assert_nil VerifyReport.parse_line(%(I, [2026-09-06T23:39:41.814076]  INFO -- ruby(:verify) ❯ [W2.4] PASS bundle check))
    assert_nil VerifyReport.parse_line(nil)
    assert_nil VerifyReport.parse_line("")
  end

  test "returns nil for the prefix followed by non-JSON" do
    assert_nil VerifyReport.parse_line("#{PREFIX} PASS bundle check")
    assert_nil VerifyReport.parse_line("#{PREFIX} {not json")
    assert_nil VerifyReport.parse_line(PREFIX)
  end

  test "returns nil for the prefix followed by a JSON array, string, number or null" do
    assert_nil VerifyReport.parse_line(%(#{PREFIX} [{"stage":"W2.4"}]))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} "W2.4"))
    assert_nil VerifyReport.parse_line("#{PREFIX} 42")
    assert_nil VerifyReport.parse_line("#{PREFIX} null")
  end

  test "returns nil when stage is missing or not a String" do
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"checks":[]}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":4,"checks":[]}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":null,"checks":[]}))
  end

  test "returns nil when checks is missing or not an Array" do
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4"}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":{"name":"x","passed":true}}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":"none"}))
  end

  test "returns nil when a check entry lacks name, is not a Hash, or has a non-boolean passed" do
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":[{"passed":true}]}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":["bundle check"]}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":[{"name":"bundle check","passed":"true"}]}))
    assert_nil VerifyReport.parse_line(%(#{PREFIX} {"stage":"W2.4","checks":[{"name":"bundle check"}]}))
  end

  test "tolerates a scrubbed value inside a string without raising" do
    line = %(#{PREFIX} {"stage":"W2.4","checks":[{"name":"rails test","passed":false,"error":"key [FILTERED] rejected"}]})
    record = VerifyReport.parse_line(line)
    assert_equal "key [FILTERED] rejected", record["checks"].first["error"]
  end

  test "keeps the optional applied, advisory, error and failing_routes keys when present" do
    line = %(#{PREFIX} {"stage":"W2.AR","attempt":1,"applied":["bundler missing gems: ran `bundle install`"],) +
           %("checks":[{"check":"route_smoke","name":"route smoke","passed":false,"advisory":true,"ms":1400,) +
           %("error":"NoMethodError: undefined method 'authenticate_user!'","failing_routes":["/"]}]})

    record = VerifyReport.parse_line(line)

    assert_equal [ "bundler missing gems: ran `bundle install`" ], record["applied"]
    check = record["checks"].first
    assert_equal true, check["advisory"]
    assert_equal "NoMethodError: undefined method 'authenticate_user!'", check["error"]
    assert_equal [ "/" ], check["failing_routes"]
  end
end
