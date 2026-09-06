require "test_helper"
require Rails.root.join("lib/roast/route_smoke")

# RouteSmoke is the Rails-free half of the :route_smoke check. The doubles below
# quack like ActionDispatch::Journey::Route (#verb, #defaults, #path.spec).
class RouteSmokeTest < ActiveSupport::TestCase
  RoutePath = Struct.new(:spec)
  FakeRoute = Struct.new(:verb, :defaults, :path)

  ROOT = "/srv/app".freeze

  # --- eligible_endpoints ----------------------------------------------------

  test "eligible_endpoints keeps a static GET route as [path, controller#action]" do
    assert_equal [ [ "/about", "pages#about" ] ],
                 RouteSmoke.eligible_endpoints([ route("/about(.:format)", controller: "pages", action: "about") ])
  end

  test "eligible_endpoints drops a non-GET route" do
    assert_empty RouteSmoke.eligible_endpoints([ route("/posts(.:format)", verb: "POST", controller: "posts", action: "create") ])
  end

  test "eligible_endpoints drops a rails/-namespaced controller (the conductor route was the only fleet-wide failure)" do
    routes = [
      route("/rails/conductor/action_mailbox/inbound_emails(.:format)",
            controller: "rails/conductor/action_mailbox/inbound_emails", action: "index"),
      route("/up(.:format)", controller: "rails/health", action: "show")
    ]
    assert_empty RouteSmoke.eligible_endpoints(routes)
  end

  test "eligible_endpoints drops active_storage/, action_mailbox/ and turbo/ controllers" do
    routes = [
      route("/blobs(.:format)", controller: "active_storage/blobs/redirect", action: "show"),
      route("/inbound(.:format)", controller: "action_mailbox/ingresses/relay/inbound_emails", action: "create"),
      route("/recede_historical_location(.:format)", controller: "turbo/native/navigation", action: "recede")
    ]
    assert_empty RouteSmoke.eligible_endpoints(routes)
  end

  test "eligible_endpoints drops a route with a dynamic segment and one with a glob" do
    routes = [
      route("/posts/:id(.:format)", controller: "posts", action: "show"),
      route("/posts/:id/edit(.:format)", controller: "posts", action: "edit"),
      route("/files/*path(.:format)", controller: "files", action: "show")
    ]
    assert_empty RouteSmoke.eligible_endpoints(routes)
  end

  test "eligible_endpoints drops a route with no controller (a mounted engine)" do
    assert_empty RouteSmoke.eligible_endpoints([ FakeRoute.new("", {}, RoutePath.new("/engine")) ])
  end

  test "eligible_endpoints strips the (.:format) suffix" do
    paths = RouteSmoke.eligible_endpoints([ route("/praise/new(.:format)", controller: "praise_notes", action: "new") ]).map(&:first)
    assert_equal [ "/praise/new" ], paths
  end

  test "eligible_endpoints de-duplicates by path, keeping the first" do
    routes = [
      route("/(.:format)", controller: "pages", action: "index"),
      route("/", controller: "home", action: "index")
    ]
    assert_equal [ [ "/", "pages#index" ] ], RouteSmoke.eligible_endpoints(routes)
  end

  # --- failure_message -------------------------------------------------------

  test "failure_message uses only the first line of a multi-line message" do
    error = exception("undefined method 'authenticate_user!' for an instance of PagesController\n\n  Did you mean? ...", [])
    assert_equal "RuntimeError: undefined method 'authenticate_user!' for an instance of PagesController",
                 RouteSmoke.failure_message(error, ROOT)
  end

  test "failure_message appends the first frame under the app root, relativised" do
    error = exception("boom", [
      "/usr/lib/ruby/gems/actionpack/lib/callbacks.rb:12:in 'run'",
      "#{ROOT}/app/controllers/pages_controller.rb:4:in 'index'",
      "#{ROOT}/app/controllers/application_controller.rb:9:in 'wrap'"
    ])
    assert_equal "RuntimeError: boom\nat app/controllers/pages_controller.rb:4:in 'index'",
                 RouteSmoke.failure_message(error, ROOT)
  end

  test "failure_message skips frames under tmp/ (the check itself) and omits the line when no app frame exists" do
    error = exception("boom", [
      "#{ROOT}/tmp/hifumi/route_smoke_test.rb:30:in 'block'",
      "/usr/lib/ruby/gems/minitest/lib/minitest.rb:1:in 'run'"
    ])
    assert_equal "RuntimeError: boom", RouteSmoke.failure_message(error, ROOT)
  end

  test "failure_message accepts a Pathname root" do
    error = exception("boom", [ "#{ROOT}/app/models/note.rb:1:in 'x'" ])
    assert_equal "RuntimeError: boom\nat app/models/note.rb:1:in 'x'", RouteSmoke.failure_message(error, Pathname.new(ROOT))
  end

  # --- read_paths ------------------------------------------------------------

  test "read_paths returns [] for a missing file" do
    Dir.mktmpdir do |dir|
      assert_equal [], RouteSmoke.read_paths(File.join(dir, "failing"))
    end
  end

  test "read_paths drops blank lines and de-duplicates" do
    Dir.mktmpdir do |dir|
      file = File.join(dir, "failing")
      File.write(file, "/\n\n/about\n/\n")
      assert_equal [ "/", "/about" ], RouteSmoke.read_paths(file)
    end
  end

  private

  def route(spec, verb: "GET", controller:, action:)
    FakeRoute.new(verb, { controller: controller, action: action }, RoutePath.new(spec))
  end

  def exception(message, backtrace)
    RuntimeError.new(message).tap { |e| e.set_backtrace(backtrace) }
  end
end
