require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RailsAppGenerator
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # `roast/` holds Roast workflow DSL files invoked as subprocesses by
    # ExecuteInstructionJob (`bin/roast lib/roast/revision_workflow.rb`).
    # They `abort()` at top-level when env vars are missing — never autoload.
    #
    # `preview/skeleton{,-overlay}/` are filesystem templates copied into
    # generated workspaces (`cp_r` in ExecuteInstructionJob#init_rails_app),
    # not Ruby modules — they contain a whole nested Rails application that
    # Zeitwerk would (correctly) refuse to load alongside this one.
    config.autoload_lib(ignore: %w[
      assets tasks roast
      preview/skeleton preview/skeleton-overlay
    ])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
