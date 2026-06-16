module Preview
  module Config
    module_function

    def domain
      Rails.configuration.preview.domain
    end

    def remote?
      domain.present?
    end

    def port_offset
      Rails.configuration.preview.port_offset
    end

    # Path (as seen INSIDE the kamal-proxy container) to a pre-issued wildcard
    # `*.preview.<domain>` certificate and its private key. When both are set,
    # preview routes are registered against this static cert instead of per-host
    # on-demand Let's Encrypt — so every preview presents an already-warm,
    # long-settled cert (no first-visit issuance window). See
    # docs/05-runbooks/02-preview-wildcard-tls.md.
    def tls_certificate_path
      Rails.configuration.preview.tls_certificate_path
    end

    def tls_private_key_path
      Rails.configuration.preview.tls_private_key_path
    end

    def wildcard_tls?
      tls_certificate_path.present? && tls_private_key_path.present?
    end
  end
end
