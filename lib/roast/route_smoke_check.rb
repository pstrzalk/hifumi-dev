# frozen_string_literal: true

# Copied by hifumi.dev's verify step into tmp/hifumi/route_smoke_test.rb of a
# generated app, run with `bin/rails test tmp/hifumi/route_smoke_test.rb`, and
# removed again. Not part of the app's own suite.
#
# One test per static GET route: the page must not raise and must not 5xx.
# Routes listed in tmp/hifumi/known_failing were already failing before this
# revision and are skipped; every failing path is appended to tmp/hifumi/failing
# so the verifier can record it (and, at baseline time, feed it back as known).
#
# Why this exists: db:prepare, zeitwerk:check and `rails test` all pass on an
# app whose page raises at request time (`before_action :authenticate_user!`
# without devise being the recorded production case). `rails test` only catches
# it if the agent happened to write a test for that action, and is skipped
# entirely when the agent wrote none.

require_relative "../../test/test_helper"
require "timeout"
require_relative "route_smoke"

class HifumiRouteSmokeTest < ActionDispatch::IntegrationTest
  KNOWN_FAILING = RouteSmoke.read_paths(File.expand_path(RouteSmoke::KNOWN_FAILING_FILE, __dir__))
  FAILING_FILE  = File.expand_path(RouteSmoke::FAILING_FILE, __dir__)

  def self.record_failure(path)
    # Open/append/close per call: one write(2) in O_APPEND mode, atomic even
    # if test_helper's parallelize kicks in above its threshold.
    File.open(FAILING_FILE, "a") { |f| f.puts path }
  end

  RouteSmoke.eligible_endpoints(Rails.application.routes.routes).each do |path, endpoint|
    test "GET #{path} (#{endpoint})" do
      skip "already failing before this revision" if KNOWN_FAILING.include?(path)

      Timeout.timeout(RouteSmoke::REQUEST_TIMEOUT_SECONDS) { get path }
      self.class.record_failure(path) if response.server_error?
      assert_not response.server_error?, "#{endpoint} responded #{response.status}"
    rescue Minitest::Assertion, Minitest::Skip
      raise
    rescue Exception => e # rubocop:disable Lint/RescueException
      # Letting the exception through prints ~70 frames: tmp/ is not one of
      # Rails' "app dirs", so the backtrace cleaner silences every line and
      # falls back to the full trace — 12k chars per failure, measured. flunk
      # with the one line the fix agent needs instead. Exception rather than
      # StandardError because a syntax error in a lazily-loaded helper is a
      # ScriptError and exactly what this check is for.
      self.class.record_failure(path)
      flunk RouteSmoke.failure_message(e, Rails.root)
    end
  end
end
