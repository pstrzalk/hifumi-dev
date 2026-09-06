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

  test "run forwards known_failing_routes to every perform call" do
    with_perform_stub(herb_lint: nil) do |_calls, kwargs|
      VerifyRevision.run(WORKSPACE, known_failing_routes: [ "/", "/about" ])
      assert_equal 5, kwargs.size
      assert kwargs.all? { |kw| kw == { known_failing_routes: [ "/", "/about" ] } }, kwargs.inspect
    end
  end

  test "run defaults known_failing_routes to []" do
    with_perform_stub(herb_lint: nil) do |_calls, kwargs|
      VerifyRevision.run(WORKSPACE)
      assert kwargs.all? { |kw| kw == { known_failing_routes: [] } }, kwargs.inspect
    end
  end

  # --- run_one -----------------------------------------------------------------

  test "run_one returns the standard result shape for a single check" do
    with_perform_stub(rails_test: false) do |calls|
      result = VerifyRevision.run_one(:rails_test, WORKSPACE)
      assert_equal [ :rails_test ], calls
      assert_equal 1, result[:checks].size
      assert_empty result[:passed]
      assert_equal [ :rails_test ], result[:failed].map { |c| c[:check] }
      assert VerifyRevision.failed?(result)
    end
  end

  test "run_one is []-safe when the check returns nil (not applicable)" do
    with_perform_stub(rails_test: nil) do
      result = VerifyRevision.run_one(:rails_test, WORKSPACE)
      assert_equal({ checks: [], passed: [], failed: [] }, result)
      refute VerifyRevision.failed?(result)
    end
  end

  # --- the two decisions the workflow rests on ---------------------------------

  test "blocking_failed? is false when only route_smoke (advisory) failed" do
    result = build_result(failed: %i[route_smoke])
    refute VerifyRevision.blocking_failed?(result)
  end

  test "blocking_failed? is true when rails_test failed" do
    result = build_result(failed: %i[route_smoke rails_test])
    assert VerifyRevision.blocking_failed?(result)
  end

  test "blocking_failed? is false when nothing failed" do
    refute VerifyRevision.blocking_failed?(build_result(failed: []))
  end

  test "failed? is true when only route_smoke failed (remediation must still trigger)" do
    assert VerifyRevision.failed?(build_result(failed: %i[route_smoke]))
  end

  # --- presentation -------------------------------------------------------------

  test "summary appends (advisory) to route_smoke and nothing to the others" do
    result = build_result(failed: %i[route_smoke])
    assert_equal "PASS bundle check\nPASS db:prepare\nFAIL route smoke (advisory)\nPASS rails test",
                 VerifyRevision.summary(result)
  end

  test "format_errors prepends HINTS[:route_smoke] to a route smoke failure and nothing to a rails_test failure" do
    result = build_result(failed: %i[route_smoke rails_test])
    errors = VerifyRevision.format_errors(result)

    assert_equal "route smoke:\n#{VerifyRevision::HINTS[:route_smoke]}\nfail route_smoke\n\n---\n\nrails test:\nfail rails_test", errors
  end

  # --- perform(:route_smoke) ----------------------------------------------------

  test "perform(:route_smoke) installs both files plus known_failing into tmp/hifumi, then removes the directory" do
    Dir.mktmpdir do |ws|
      seen = nil
      stub = lambda do |workspace, cmd, check, name|
        dir = File.join(workspace, "tmp/hifumi")
        seen = {
          files: Dir.children(dir).sort,
          known: File.read(File.join(dir, "known_failing")),
          smoke_rb: File.read(File.join(dir, "route_smoke.rb")),
          smoke_test: File.read(File.join(dir, "route_smoke_test.rb")),
          cmd: cmd, check: check, name: name
        }
        { check: check, name: name, passed: true, output: "", ms: 1 }
      end

      result = with_run_cmd_stub(stub) { VerifyRevision.perform(:route_smoke, ws, known_failing_routes: [ "/", "/about" ]) }

      assert_equal %w[known_failing route_smoke.rb route_smoke_test.rb], seen[:files]
      assert_equal "/\n/about", seen[:known]
      assert_equal File.read(Rails.root.join("lib/roast/route_smoke.rb")), seen[:smoke_rb]
      assert_equal File.read(Rails.root.join("lib/roast/route_smoke_check.rb")), seen[:smoke_test]
      assert_equal "bin/rails test tmp/hifumi/route_smoke_test.rb", seen[:cmd]
      assert_equal :route_smoke, seen[:check]
      assert_equal "route smoke", seen[:name]
      refute Dir.exist?(File.join(ws, "tmp/hifumi")), "tmp/hifumi must be removed after the run"
      assert_equal [], result[:failing_routes]
      assert result[:passed]
    end
  end

  test "perform(:route_smoke) removes tmp/hifumi even when the shell-out raises" do
    Dir.mktmpdir do |ws|
      stub = ->(*) { raise IOError, "popen failed" }
      assert_raises(IOError) do
        with_run_cmd_stub(stub) { VerifyRevision.perform(:route_smoke, ws) }
      end
      refute Dir.exist?(File.join(ws, "tmp/hifumi"))
    end
  end

  test "perform(:route_smoke) returns failing_routes read from tmp/hifumi/failing before cleanup" do
    Dir.mktmpdir do |ws|
      stub = lambda do |workspace, _cmd, check, name|
        File.write(File.join(workspace, "tmp/hifumi/failing"), "/\n/praise\n/\n")
        { check: check, name: name, passed: false, output: "1 failure", ms: 5 }
      end

      result = with_run_cmd_stub(stub) { VerifyRevision.perform(:route_smoke, ws) }

      assert_equal [ "/", "/praise" ], result[:failing_routes]
      refute result[:passed]
      assert_equal "1 failure", result[:output]
    end
  end

  # --- run_cmd ------------------------------------------------------------------

  test "run_cmd records the check symbol, the display name, the output and a non-negative Integer ms" do
    Dir.mktmpdir do |ws|
      result = VerifyRevision.run_cmd(ws, "echo hello", :probe, "probe check")

      assert_equal :probe, result[:check]
      assert_equal "probe check", result[:name]
      assert result[:passed]
      assert_equal "hello\n", result[:output]
      assert_kind_of Integer, result[:ms]
      assert_operator result[:ms], :>=, 0
    end
  end

  test "run_cmd reports a failing command with its combined stdout+stderr" do
    Dir.mktmpdir do |ws|
      result = VerifyRevision.run_cmd(ws, "sh -c 'echo oops >&2; exit 1'", :probe, "probe check")

      refute result[:passed]
      assert_equal "oops\n", result[:output]
    end
  end

  test "run_cmd escapes a workspace path with spaces" do
    Dir.mktmpdir do |root|
      ws = File.join(root, "with space")
      FileUtils.mkdir_p(ws)
      result = VerifyRevision.run_cmd(ws, "pwd", :probe, "probe")

      assert result[:passed], result[:output]
      assert_equal File.realpath(ws), File.realpath(result[:output].strip)
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

  NAMES = {
    bundle_check: "bundle check", db_prepare: "db:prepare", zeitwerk_check: "zeitwerk check",
    route_smoke: "route smoke", rails_test: "rails test"
  }.freeze

  # A result hash in the shape VerifyRevision.run returns, over a fixed
  # four-check run, with the given checks failing.
  def build_result(failed:)
    checks = %i[bundle_check db_prepare route_smoke rails_test].map do |check|
      passed = !failed.include?(check)
      { check: check, name: NAMES.fetch(check), passed: passed, output: passed ? "" : "fail #{check}", ms: 1 }
    end
    { checks: checks, passed: checks.select { |c| c[:passed] }, failed: checks.reject { |c| c[:passed] } }
  end

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
  # outcome per check. Defaults to pass for unspecified checks. Yields the
  # ordered list of checks called and the kwargs each call received.
  def with_perform_stub(results)
    calls = []
    kwargs = []
    VerifyRevision.singleton_class.alias_method(:__orig_perform, :perform)
    VerifyRevision.define_singleton_method(:perform) do |check, _ws, **kw|
      calls << check
      kwargs << kw
      val = results.fetch(check, true)
      next nil if val.nil?

      { check: check, name: check, passed: val, output: val ? "" : "fail", ms: 1 }
    end
    yield calls, kwargs
  ensure
    VerifyRevision.singleton_class.alias_method(:perform, :__orig_perform)
    VerifyRevision.singleton_class.send(:remove_method, :__orig_perform)
  end

  # Replace the shell seam (VerifyRevision.run_cmd) with `stub`, a callable of
  # (workspace, cmd, check, name), for the block's duration.
  def with_run_cmd_stub(stub)
    VerifyRevision.singleton_class.alias_method(:__orig_run_cmd, :run_cmd)
    VerifyRevision.define_singleton_method(:run_cmd) { |*args| stub.call(*args) }
    yield
  ensure
    VerifyRevision.singleton_class.alias_method(:run_cmd, :__orig_run_cmd)
    VerifyRevision.singleton_class.send(:remove_method, :__orig_run_cmd)
  end
end
