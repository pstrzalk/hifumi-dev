ENV["RAILS_ENV"] ||= "test"
require "tmpdir"

# Test workspaces must live OUTSIDE the generator repo: `rails new` walks up
# from cwd via inside_application? and refuses if it finds a parent Rails app.
TEST_WORKSPACES_ROOT = File.join(Dir.tmpdir, "rails-app-generator-test-workspaces")
ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] ||=
  File.join(TEST_WORKSPACES_ROOT, "pid_#{Process.pid}")

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
      ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] =
        File.join(TEST_WORKSPACES_ROOT, "worker_#{worker}")
    end

    parallelize_teardown do |worker|
      FileUtils.rm_rf(File.join(TEST_WORKSPACES_ROOT, "worker_#{worker}"))
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
