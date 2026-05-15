Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self, :https
    policy.font_src    :self, :https, :data
    policy.img_src     :self, :https, :data
    policy.object_src  :none
    policy.script_src  :self, :https
    policy.style_src   :self, :https, :unsafe_inline   # Tailwind / inline styles in views
    policy.connect_src :self, :https, "wss:", "ws:"    # Action Cable WebSocket

    # Preview iframe is cross-origin in prod (hifumi.dev → <id>.preview.hifumi.dev),
    # same-site in dev (localhost:3000 → localhost:30XX). Read PREVIEW_DOMAIN
    # directly from ENV here rather than via Preview::Config — initializers load
    # alphabetically and content_security_policy.rb loads BEFORE preview_config.rb.
    if (preview_domain = ENV["PREVIEW_DOMAIN"]).present?
      policy.frame_src :self, "https://*.preview.#{preview_domain}"
    else
      policy.frame_src :self, "http://localhost:*"     # dev iframe at localhost:30XX
    end
  end

  # Nonce must be session-independent: anonymous visitors haven't written to
  # the session yet, so `request.session.id` is nil/empty and the resulting
  # `nonce-""` is rejected by browsers (blocks every inline script — importmap,
  # Stimulus boot, csrf meta). Phase 4 will add `reset_session` for no-consent
  # visitors, which would compound the issue. SecureRandom is computed once
  # per request via ActionDispatch::ContentSecurityPolicy::Request memoization.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
end
