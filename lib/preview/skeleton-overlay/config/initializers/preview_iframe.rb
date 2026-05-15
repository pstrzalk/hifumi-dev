# Allow this generated app to be embedded in the hifumi-dev preview
# iframe. The generator runs at http://localhost:3000; this app runs at
# http://localhost:#{3000 + project.id}. Different ports = different origins,
# so the default X-Frame-Options=SAMEORIGIN blocks framing.
#
# Strip the header. The preview is intentionally framed by the generator and
# nothing else binds the preview port from outside the host.
Rails.application.config.action_dispatch.default_headers.delete("X-Frame-Options")

# In production the preview is reached through kamal-proxy at
# <project_id>.preview.<domain>. Rails 8 dev HostAuthorization only allows
# localhost / .localhost / loopback by default and would 403 the request
# before the app sees it. PreviewManager passes PREVIEW_HOST per container.
Rails.application.config.hosts << ENV["PREVIEW_HOST"] if ENV["PREVIEW_HOST"].present?
