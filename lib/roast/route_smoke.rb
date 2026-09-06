# frozen_string_literal: true

# Pure helpers for the :route_smoke check. Free of Rails so the generator's own
# suite can exercise them with plain doubles. Copied into a generated app's
# tmp/hifumi/ alongside route_smoke_check.rb for the duration of one check.
module RouteSmoke
  # Routes Rails mounts itself. /rails/conductor/action_mailbox/inbound_emails
  # 500s on every generated app (the table is never migrated) and was the only
  # smoke failure across all 29 existing workspaces — it is not the app's code.
  SKIPPED_NAMESPACES = %w[rails/ active_storage/ action_mailbox/ turbo/].freeze

  # A page that takes longer than this is broken for a preview anyway, and the
  # `generation` queue is 1 process x 1 thread — an unbounded request would
  # block every tenant's build.
  REQUEST_TIMEOUT_SECONDS = 10

  # File names under tmp/hifumi/ shared between VerifyRevision (writes the
  # first, reads the second) and route_smoke_check.rb (reads, appends).
  KNOWN_FAILING_FILE = "known_failing"
  FAILING_FILE       = "failing"

  # routes: ActionDispatch::Journey::Route-alikes (#verb, #defaults, #path).
  # Returns [path, "controller#action"] pairs, one per path.
  def self.eligible_endpoints(routes)
    routes.filter_map do |route|
      next unless route.verb.to_s.include?("GET")

      controller = route.defaults[:controller].to_s
      next if controller.empty?
      next if SKIPPED_NAMESPACES.any? { |ns| controller.start_with?(ns) }

      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      # Dynamic segments need a real record id. A generated app's database is
      # usually empty, so :id would resolve to nil and the route would be
      # skipped anyway — see "What We're NOT Doing" in the 2026-09-05 plan.
      next if path.include?(":") || path.include?("*")

      [ path, "#{controller}##{route.defaults[:action]}" ]
    end.uniq(&:first)
  end

  # The one line the fix agent needs, plus the first frame in the app's own
  # code when there is one. Frames under tmp/ are the check itself.
  def self.failure_message(exception, root)
    first = "#{exception.class}: #{exception.message.to_s.lines.first.to_s.strip}"
    frame = exception.backtrace.to_a.find do |line|
      line.start_with?("#{root}/") && !line.start_with?("#{root}/tmp/")
    end
    frame ? "#{first}\nat #{frame.delete_prefix("#{root}/")}" : first
  end

  # One path per line; missing file means none.
  def self.read_paths(file)
    File.exist?(file) ? File.readlines(file, chomp: true).reject(&:empty?).uniq : []
  end
end
