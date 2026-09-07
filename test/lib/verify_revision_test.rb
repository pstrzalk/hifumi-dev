require "test_helper"
require Rails.root.join("lib/roast/verify_revision")

# VerifyRevision is a deterministic Rails-workspace verifier. We don't run a real
# Rails workspace in unit tests; we stub `perform` to control which checks pass.
class VerifyRevisionTest < ActiveSupport::TestCase
  WORKSPACE = "/tmp/fake_ws_for_verify_test".freeze

  test "CHECKS is the reworked five-check set; boot_check and herb_lint are gone along with the herb guard" do
    assert_equal %i[bundle_check db_prepare zeitwerk_check route_smoke rails_test], VerifyRevision::CHECKS
    refute_includes VerifyRevision::CHECKS, :boot_check, "dominated by db_prepare, which boots the same app first"
    refute_includes VerifyRevision::CHECKS, :herb_lint, "never ran: herb is not in the skeleton Gemfile"
    refute VerifyRevision.respond_to?(:gem_available?), "herb_lint was its only caller"
  end

  test "all-pass with no tests: returns the four applicable checks in order, none failed" do
    with_perform_stub(
      bundle_check: true,
      db_prepare: true,
      zeitwerk_check: true,
      route_smoke: true,
      rails_test: nil # the realistic skip: a revision that wrote no tests
    ) do |_calls|
      result = VerifyRevision.run(WORKSPACE)
      refute VerifyRevision.failed?(result)
      assert_equal 4, result[:checks].size, "nil check (rails_test) is filtered"
      assert_equal %i[bundle_check db_prepare zeitwerk_check route_smoke],
                   result[:checks].map { |c| c[:name].to_sym }
    end
  end

  test "all-pass with tests: returns all five checks in order" do
    with_perform_stub({}) do |calls|
      result = VerifyRevision.run(WORKSPACE)
      refute VerifyRevision.failed?(result)
      assert_equal %i[bundle_check db_prepare zeitwerk_check route_smoke rails_test], calls
      assert_equal 5, result[:checks].size
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
    with_perform_stub(bundle_check: true, db_prepare: false, zeitwerk_check: true, route_smoke: true, rails_test: true) do |calls|
      VerifyRevision.run(WORKSPACE)
      assert_equal %i[bundle_check db_prepare zeitwerk_check route_smoke rails_test], calls
    end
  end

  test "a run where only route_smoke fails: failed? (remediation triggers) but not blocking_failed? (the commit stands)" do
    with_perform_stub(route_smoke: false) do
      result = VerifyRevision.run(WORKSPACE)
      assert VerifyRevision.failed?(result)
      refute VerifyRevision.blocking_failed?(result)
      assert_equal [ :route_smoke ], result[:failed].map { |c| c[:check] }
    end
  end

  test "run forwards known_failing_routes to every perform call" do
    with_perform_stub({}) do |_calls, kwargs|
      VerifyRevision.run(WORKSPACE, known_failing_routes: [ "/", "/about" ])
      assert_equal 5, kwargs.size
      assert kwargs.all? { |kw| kw == { known_failing_routes: [ "/", "/about" ] } }, kwargs.inspect
    end
  end

  test "run defaults known_failing_routes to []" do
    with_perform_stub({}) do |_calls, kwargs|
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

  # --- tally -------------------------------------------------------------------
  # run, run_one and the W2.B baseline all return the same shape. W2.B assembles
  # its list itself (bundle_check from AutoRemediate.ensure_bundle, then
  # route_smoke), so the split lives here rather than inside either runner.

  test "tally splits a mixed list into passed and failed while keeping checks in order" do
    checks = [
      { check: :bundle_check, passed: false },
      { check: :route_smoke, passed: true },
      { check: :rails_test, passed: false }
    ]
    result = VerifyRevision.tally(checks)

    assert_equal checks, result[:checks], "order is the order the checks ran in"
    assert_equal [ :route_smoke ], result[:passed].map { |c| c[:check] }
    assert_equal [ :bundle_check, :rails_test ], result[:failed].map { |c| c[:check] }
  end

  test "tally of an empty list is the empty result run_one returns for a skipped check" do
    assert_equal({ checks: [], passed: [], failed: [] }, VerifyRevision.tally([]))
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
    assert_equal "PASS bundle check\nPASS db:prepare\nPASS zeitwerk check\nFAIL route smoke (advisory)\nPASS rails test",
                 VerifyRevision.summary(result)
  end

  test "format_errors prepends HINTS[:route_smoke] to a route smoke failure and nothing to a rails_test failure" do
    result = build_result(failed: %i[route_smoke rails_test])
    errors = VerifyRevision.format_errors(result)

    assert_equal "route smoke:\n#{VerifyRevision::HINTS[:route_smoke]}\nfail route_smoke\n\n---\n\nrails test:\nfail rails_test", errors
  end

  # --- cap_error ------------------------------------------------------------------

  test "cap_error returns short output unchanged" do
    assert_equal "1 runs, 1 failures", VerifyRevision.cap_error("1 runs, 1 failures")
  end

  test "cap_error returns output of exactly ERROR_CAP_CHARS unchanged (boundary)" do
    text = "x" * VerifyRevision::ERROR_CAP_CHARS
    assert_equal text, VerifyRevision.cap_error(text)
  end

  test "cap_error truncates longer output, keeping the first ERROR_CAP_CHARS - ERROR_TAIL_CHARS chars, the last ERROR_TAIL_CHARS, and a marker between" do
    head_size = VerifyRevision::ERROR_CAP_CHARS - VerifyRevision::ERROR_TAIL_CHARS
    text = ("a" * head_size) + ("b" * 2_500) + ("c" * VerifyRevision::ERROR_TAIL_CHARS)

    capped = VerifyRevision.cap_error(text)

    assert capped.start_with?("a" * head_size), "head must be preserved verbatim"
    assert capped.end_with?("c" * VerifyRevision::ERROR_TAIL_CHARS), "tail (the Minitest counts line) must be preserved verbatim"
    assert_includes capped, "\n[... 2500 chars truncated ...]\n"
    refute_includes capped, "b", "the middle is what gets dropped"
  end

  test "cap_error handles nil" do
    assert_equal "", VerifyRevision.cap_error(nil)
  end

  test "format_errors caps each failing check's output after the hint, keeping the name prefix and the --- separator" do
    head_size = VerifyRevision::ERROR_CAP_CHARS - VerifyRevision::ERROR_TAIL_CHARS
    long = "L" * (VerifyRevision::ERROR_CAP_CHARS + 500)
    result = build_result(failed: %i[route_smoke rails_test])
    result[:failed].each { |c| c[:output] = long }

    parts = VerifyRevision.format_errors(result).split("\n\n---\n\n")

    assert_equal 2, parts.size
    assert parts[0].start_with?("route smoke:\n#{VerifyRevision::HINTS[:route_smoke]}\n#{'L' * head_size}\n[... 500 chars truncated ...]\n")
    assert parts[1].start_with?("rails test:\n#{'L' * head_size}\n[... 500 chars truncated ...]\n")
    parts.each { |part| assert part.end_with?("L" * VerifyRevision::ERROR_TAIL_CHARS) }
  end

  # --- sentinel -------------------------------------------------------------------

  test "sentinel emits one prefixed line of valid JSON that round-trips through VerifyReport.parse_line" do
    line = VerifyRevision.sentinel(build_result(failed: []), stage: "W2.4")

    assert_equal 1, line.lines.size
    assert line.start_with?("#{VerifyRevision::SENTINEL_PREFIX} {")
    record = VerifyReport.parse_line(line)
    assert_equal "W2.4", record["stage"]
    assert_equal 1, record["attempt"]
    assert_equal %w[bundle_check db_prepare zeitwerk_check route_smoke rails_test], record["checks"].map { |c| c["check"] }
    assert_equal [ "bundle check", "db:prepare", "zeitwerk check", "route smoke", "rails test" ], record["checks"].map { |c| c["name"] }
    assert record["checks"].all? { |c| c["passed"] == true && c["ms"] == 1 }
  end

  test "sentinel includes error (capped) only for failing checks, advisory only for route_smoke, failing_routes only when carried" do
    result = build_result(failed: %i[route_smoke rails_test])
    smoke = result[:checks].find { |c| c[:check] == :route_smoke }
    smoke[:failing_routes] = [ "/" ]
    rails_test = result[:checks].find { |c| c[:check] == :rails_test }
    rails_test[:output] = "E" * (VerifyRevision::ERROR_CAP_CHARS + 10)

    checks = VerifyReport.parse_line(VerifyRevision.sentinel(result, stage: "W2.RV", attempt: 2))["checks"].index_by { |c| c["check"] }

    assert_equal false, checks["bundle_check"].key?("error")
    assert_equal "fail route_smoke", checks["route_smoke"]["error"]
    assert_includes checks["rails_test"]["error"], "[... 10 chars truncated ...]"
    assert_equal [ true, false, false, false, false ], %w[route_smoke bundle_check db_prepare zeitwerk_check rails_test].map { |c| checks[c]["advisory"] }
    assert_equal [ "/" ], checks["route_smoke"]["failing_routes"]
    assert_equal [ false, false, false, false ], %w[bundle_check db_prepare zeitwerk_check rails_test].map { |c| checks[c].key?("failing_routes") }
  end

  test "sentinel includes applied only when given, and attempt defaults to 1" do
    result = build_result(failed: [])
    without = VerifyReport.parse_line(VerifyRevision.sentinel(result, stage: "W2.4"))
    with = VerifyReport.parse_line(VerifyRevision.sentinel(result, stage: "W2.AR", applied: [ "bundler missing gems: ran `bundle install`" ]))

    refute without.key?("applied")
    assert_equal 1, without["attempt"]
    assert_equal [ "bundler missing gems: ran `bundle install`" ], with["applied"]
  end

  test "sentinel survives invalid UTF-8 in a failing check's output (JSON.generate would otherwise raise inside the verify cog)" do
    result = build_result(failed: %i[rails_test])
    result[:checks].find { |c| c[:check] == :rails_test }[:output] = "bad byte \xFF here".b

    record = VerifyReport.parse_line(VerifyRevision.sentinel(result, stage: "W2.4"))

    assert_equal "bad byte \uFFFD here", record["checks"].last["error"]
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
      assert_equal [ "bin/rails", "test", "tmp/hifumi/route_smoke_test.rb" ], seen[:cmd]
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
      result = VerifyRevision.run_cmd(ws, %w[echo hello], :probe, "probe check")

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
      result = VerifyRevision.run_cmd(ws, [ "sh", "-c", "echo oops >&2; exit 1" ], :probe, "probe check")

      refute result[:passed]
      assert_equal "oops\n", result[:output]
    end
  end

  test "run_cmd runs the program with the workspace as cwd, spaces in the path included" do
    Dir.mktmpdir do |root|
      ws = File.join(root, "with space")
      FileUtils.mkdir_p(ws)
      result = VerifyRevision.run_cmd(ws, %w[pwd], :probe, "probe")

      assert result[:passed], result[:output]
      assert_equal File.realpath(ws), File.realpath(result[:output].strip)
    end
  end

  test "run_cmd passes arguments to the program verbatim — no shell ever interprets them" do
    Dir.mktmpdir do |ws|
      hostile = "$HOME; rm -rf / && `id` | cat"
      result = VerifyRevision.run_cmd(ws, [ "printf", "%s", hostile ], :probe, "probe")

      assert result[:passed]
      assert_equal hostile, result[:output]
    end
  end

  test "run_cmd reports a program that cannot be started as a failed check, not an exception" do
    Dir.mktmpdir do |ws|
      result = VerifyRevision.run_cmd(ws, [ "hifumi-no-such-program" ], :probe, "probe")

      refute result[:passed]
      assert_match(/Errno::ENOENT/, result[:output])
      assert_kind_of Integer, result[:ms]
    end
  end

  test "run_cmd reports a missing workspace as a failed check" do
    result = VerifyRevision.run_cmd("/nonexistent/hifumi/workspace", %w[pwd], :probe, "probe")

    refute result[:passed]
    assert_match(/Errno::ENOENT/, result[:output])
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

  # A result hash in the shape VerifyRevision.run returns, over a full
  # five-check run, with the given checks failing.
  def build_result(failed:)
    checks = VerifyRevision::CHECKS.map do |check|
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
