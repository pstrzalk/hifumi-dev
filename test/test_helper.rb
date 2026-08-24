ENV["RAILS_ENV"] ||= "test"
require "tmpdir"

# Test workspaces must live OUTSIDE the generator repo: `rails new` walks up
# from cwd via inside_application? and refuses if it finds a parent Rails app.
TEST_WORKSPACES_ROOT = File.join(Dir.tmpdir, "hifumi-dev-test-workspaces")
ENV["HIFUMI_DEV_WORKSPACE_ROOT"] ||=
  File.join(TEST_WORKSPACES_ROOT, "pid_#{Process.pid}")

# Disable git's background housekeeping for every git subprocess a test spawns.
# It writes transient lock files under .git (e.g. objects/maintenance.lock) that
# vanish between a directory walk and the per-entry operation, so any test that
# chmods or removes a tree containing a git repo can ENOENT — including
# Dir.mktmpdir's own cleanup, which no application-side fix can reach. Seen in
# CI (git 2.47) across unrelated tests; local git 2.44 rarely triggers it.
# GIT_CONFIG_COUNT injects config into every child git without touching the
# developer's global config.
ENV["GIT_CONFIG_COUNT"] = "2"
ENV["GIT_CONFIG_KEY_0"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_0"] = "false"
ENV["GIT_CONFIG_KEY_1"] = "gc.auto"
ENV["GIT_CONFIG_VALUE_1"] = "0"

require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Scope the generated-app workspace root per worker so parallel processes
    # never collide on the same project_<id>/ filesystem path (parallel tests
    # isolate DBs per worker, but the filesystem is shared by default).
    parallelize_setup do |worker|
      ENV["HIFUMI_DEV_WORKSPACE_ROOT"] =
        File.join(TEST_WORKSPACES_ROOT, "worker_#{worker}")
    end

    parallelize_teardown do |worker|
      FileUtils.rm_rf(File.join(TEST_WORKSPACES_ROOT, "worker_#{worker}"))
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Build a user via the model so the encrypted openrouter_api_key
    # round-trips through the `encrypts` callback. Fixtures can't do this
    # (raw INSERT bypasses callbacks).
    def create_user(email: nil, openrouter_api_key: nil)
      email ||= "u-#{SecureRandom.hex(4)}@example.com"
      User.create!(
        email: email,
        password: "password123",
        profile_attributes: {
          first_name: "Test", last_name: "User",
          openrouter_api_key: openrouter_api_key || "sk-or-test-#{SecureRandom.hex(8)}"
        }
      )
    end

    # Set/clear ENV keys for the block's duration (nil deletes the key),
    # restoring the originals afterwards.
    def with_env(overrides)
      originals = overrides.keys.to_h { |k| [ k, ENV[k] ] }
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end

class ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
end
