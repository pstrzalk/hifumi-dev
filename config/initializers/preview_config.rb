Rails.application.config.preview = ActiveSupport::OrderedOptions.new
Rails.application.config.preview.domain = ENV["PREVIEW_DOMAIN"]   # e.g. "hifumi.dev" in prod; nil in dev
Rails.application.config.preview.port_offset = 3000               # dev: localhost:#{3000 + project.id}

# Static wildcard cert for preview hosts (paths as seen inside the kamal-proxy
# container). Both unset = per-host on-demand Let's Encrypt (the default). Set
# both to switch every preview onto a pre-issued `*.preview.<domain>` cert.
Rails.application.config.preview.tls_certificate_path = ENV["PREVIEW_TLS_CERTIFICATE_PATH"]
Rails.application.config.preview.tls_private_key_path = ENV["PREVIEW_TLS_PRIVATE_KEY_PATH"]
