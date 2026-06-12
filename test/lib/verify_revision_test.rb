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
      assert_equal [ :bundle_check ], calls,
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

  test "with_clean_bundler_env hides parent's BUNDLE_GEMFILE so workspace bundle commands resolve against the workspace" do
    # Roast itself runs under `bundle exec`, which sets BUNDLE_GEMFILE to the
    # generator's Gemfile. If that leaked into a `bundle check` cd'd into a
    # workspace, bundler would resolve against the wrong bundle. The whole
    # point of with_clean_bundler_env is to prevent that leak.
    parent_gemfile = ENV["BUNDLE_GEMFILE"]
    refute_nil parent_gemfile, "test setup assumes we're running under bundle exec"

    inside = "STILL_SET"
    VerifyRevision.with_clean_bundler_env { inside = ENV["BUNDLE_GEMFILE"] }
    refute_equal parent_gemfile, inside,
                 "BUNDLE_GEMFILE leaked inside the block — workspace bundle commands would resolve against the parent Gemfile"
  end

  test "with_clean_bundler_env delegates to Bundler.with_unbundled_env (regression: hand-rolled scrub stripped BUNDLE_PATH)" do
    # The earlier implementation stripped every BUNDLE_*-prefixed var, which
    # over-deleted: it also dropped BUNDLE_PATH (set globally to
    # /usr/local/bundle by the Dockerfile, where every bundle install
    # deposits gems). With BUNDLE_PATH gone, subprocess `bundle check`
    # defaulted to a different lookup path and reported gems missing even
    # after `bundle install` had populated /usr/local/bundle.
    # Bundler.with_unbundled_env reverts only what bundler itself set on
    # entering the bundle, leaving Dockerfile globals intact.
    delegated = false
    original = Bundler.method(:with_unbundled_env)
    Bundler.singleton_class.define_method(:with_unbundled_env) do |&blk|
      delegated = true
      original.call(&blk)
    end
    VerifyRevision.with_clean_bundler_env { :ok }
    assert delegated, "with_clean_bundler_env must use Bundler's primitive"
  ensure
    Bundler.singleton_class.define_method(:with_unbundled_env, &original) if original
  end

  test "with_clean_bundler_env returns the block's value and propagates exceptions" do
    assert_equal 42, VerifyRevision.with_clean_bundler_env { 42 }

    raised = assert_raises(RuntimeError) do
      VerifyRevision.with_clean_bundler_env { raise "boom" }
    end
    assert_equal "boom", raised.message
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
