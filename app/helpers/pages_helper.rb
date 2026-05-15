module PagesHelper
  PRIVACY_LAST_UPDATED = Date.new(2026, 5, 15).freeze

  def operator
    Rails.application.config.operator
  end

  def operator_configured?
    operator[:name].present?
  end

  def privacy_last_updated
    PRIVACY_LAST_UPDATED
  end
end
