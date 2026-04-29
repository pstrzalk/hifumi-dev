Rails.application.config.preview = ActiveSupport::OrderedOptions.new
Rails.application.config.preview.domain = ENV["PREVIEW_DOMAIN"]   # e.g. "hifumi.dev" in prod; nil in dev
Rails.application.config.preview.port_offset = 3000               # dev: localhost:#{3000 + project.id}
