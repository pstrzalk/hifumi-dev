# Allow this generated app to be embedded in the rails-app-generator preview
# iframe. The generator runs at http://localhost:3000; this app runs at
# http://localhost:#{3000 + project.id}. Different ports = different origins,
# so the default X-Frame-Options=SAMEORIGIN blocks framing.
#
# Strip the header. The preview is intentionally framed by the generator and
# nothing else binds the preview port from outside the host.
Rails.application.config.action_dispatch.default_headers.delete("X-Frame-Options")
