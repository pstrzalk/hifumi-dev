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

  test "with_clean_bundler_env delegates to Bundler.with_unbundled_env" do
    # Bundler's primitive is what knows how to undo `bundle exec` (BUNDLE_GEMFILE,
    # BUNDLE_BIN_PATH, the -rbundler/setup in RUBYOPT, the RUBYLIB entry). The
    # hand-rolled scrubber it replaced got that list wrong once already.
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

  # Bundler.with_unbundled_env deletes EVERY BUNDLE_* variable, not only what
  # `bundle exec` set. In the production image BUNDLE_PATH and BUNDLE_WITHOUT
  # are Dockerfile globals; losing them made every workspace `bundle check`
  # report the whole lockfile missing (2026-09-03). These pin the restore.

  test "with_clean_bundler_env restores the image's BUNDLE_PATH and BUNDLE_WITHOUT while still dropping BUNDLE_GEMFILE" do
    with_original_env_stub(
      "BUNDLE_GEMFILE" => "/rails/Gemfile", "BUNDLE_BIN_PATH" => "/x/bundle", "RUBYOPT" => "-rbundler/setup",
      "BUNDLE_PATH" => "/usr/local/bundle", "BUNDLE_WITHOUT" => "development", "BUNDLE_APP_CONFIG" => "/usr/local/bundle"
    ) do
      inside = VerifyRevision.with_clean_bundler_env { ENV.to_h.slice(*%w[BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH BUNDLE_WITHOUT BUNDLE_APP_CONFIG]) }

      assert_equal({ "BUNDLE_PATH" => "/usr/local/bundle", "BUNDLE_WITHOUT" => "development" }, inside)
    end
  end

  test "with_clean_bundler_env adds nothing when the original env carries no image-level Bundler vars (dev)" do
    with_original_env_stub("BUNDLE_GEMFILE" => "/rails/Gemfile", "RUBYOPT" => "-rbundler/setup", "BUNDLE_PATH" => nil, "BUNDLE_WITHOUT" => nil) do
      inside = VerifyRevision.with_clean_bundler_env { ENV.to_h.select { |k, _| k.start_with?("BUNDLE_") } }

      assert_empty inside
    end
  end

  test "with_clean_bundler_env leaves the parent process env untouched afterwards" do
    before = ENV.to_h
    VerifyRevision.with_clean_bundler_env { ENV["BUNDLE_PATH"] = "/leaked" }

    assert_equal before, ENV.to_h
  end

  test "with_clean_bundler_env returns the block's value and propagates exceptions" do
    assert_equal 42, VerifyRevision.with_clean_bundler_env { 42 }

    raised = assert_raises(RuntimeError) do
      VerifyRevision.with_clean_bundler_env { raise "boom" }
    end
    assert_equal "boom", raised.message
  end

  private

  # Bundler.unbundled_env builds on Bundler.original_env (the env before
  # `bundle exec`), so swapping that one method is enough to simulate the
  # production image's env from a dev box. nil removes a key.
  def with_original_env_stub(overrides)
    original = Bundler.method(:original_env)
    fake = original.call.merge(overrides).compact
    Bundler.singleton_class.define_method(:original_env) { fake.dup }
    yield
  ensure
    Bundler.singleton_class.define_method(:original_env, &original) if original
  end

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
