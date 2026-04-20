ENV["RAILS_ENV"] ||= "test"
ENV["RAILS_APP_GENERATOR_WORKSPACE_ROOT"] ||=
  File.expand_path("../tmp/test_workspaces/pid_#{Process.pid}", __dir__)

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
        Rails.root.join("tmp/test_workspaces", "worker_#{worker}").to_s
    end

    parallelize_teardown do |worker|
      FileUtils.rm_rf(Rails.root.join("tmp/test_workspaces", "worker_#{worker}"))
    end

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
