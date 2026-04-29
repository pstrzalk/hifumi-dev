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
  end
end
