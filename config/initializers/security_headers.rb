# Opt every response into an origin-keyed agent cluster.
#
# `Origin-Agent-Cluster: ?1` disables the legacy `document.domain` setter for the
# origin, so a page on the generator (hifumi.dev) and a page on an untrusted
# preview (<id>.preview.hifumi.dev) can never opt into the same agent cluster and
# relax the same-origin policy by both setting `document.domain` to the shared
# parent. Sent in every environment (harmless where there are no subdomains).
#
# Mutate ActionDispatch::Response.default_headers directly: by the time
# config/initializers run, the `action_dispatch.configure` railtie has already
# copied config.action_dispatch.default_headers into the response class, so
# editing the config here would be a no-op.
ActionDispatch::Response.default_headers =
  ActionDispatch::Response.default_headers.merge(
    "Origin-Agent-Cluster" => "?1"
  )
