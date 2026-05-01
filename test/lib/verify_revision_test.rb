require "test_helper"
require Rails.root.join("lib/roast/verify_revision")

# VerifyRevision is a deterministic Rails-workspace verifier. We don't run a real
# Rails workspace in unit tests; we stub `perform` to control which checks pass.
class VerifyRevisionTest < ActiveSupport::TestCase
  WORKSPACE = "/tmp/fake_ws_for_verify_test".freeze

  test "all-pass: returns every check, none failed" do
    with_perform_stub(
      bundle_check: true,
      db_prepare: true,
      herb_lint: nil, # not applicable, e.g. herb gem absent
      boot_check: true,
      rails_test: true
    ) do |_calls|
      result = VerifyRevision.run(WORKSPACE)
      refute VerifyRevision.failed?(result)
      assert_equal 4, result[:checks].size, "nil check (herb) is filtered"
      assert_equal %i[bundle_check db_prepare boot_check rails_test],
                   result[:checks].map { |c| c[:name].to_sym }
    end
  end

  test "bundle_check failure short-circuits the cascade" do
    with_perform_stub(bundle_check: false) do |calls|
      result = VerifyRevision.run(WORKSPACE)
      assert VerifyRevision.failed?(result)
      assert_equal [:bundle_check], calls,
                   "no downstream check should run after bundle_check fails — they'd all repeat the same stacktrace"
      assert_equal 1, result[:checks].size
    end
  end

  test "db_prepare failure does NOT short-circuit (later checks may report independent errors)" do
    with_perform_stub(bundle_check: true, db_prepare: false, herb_lint: nil, boot_check: true, rails_test: true) do |calls|
      VerifyRevision.run(WORKSPACE)
      assert_equal %i[bundle_check db_prepare herb_lint boot_check rails_test], calls
    end
  end

  private

  # Replace VerifyRevision.perform with a stub that returns the configured
  # outcome per check. Defaults to pass for unspecified checks.
  def with_perform_stub(results)
    calls = []
    VerifyRevision.singleton_class.alias_method(:__orig_perform, :perform)
    VerifyRevision.define_singleton_method(:perform) do |check, _ws|
      calls << check
      val = results.fetch(check, true)
      next nil if val.nil?

      { name: check, passed: val, output: val ? "" : "fail" }
    end
    yield calls
  ensure
    VerifyRevision.singleton_class.alias_method(:perform, :__orig_perform)
    VerifyRevision.singleton_class.send(:remove_method, :__orig_perform)
  end
end
