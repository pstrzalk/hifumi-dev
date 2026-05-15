class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :enforce_cookie_consent

  helper_method :cookie_consent_given?

  private

  def enforce_cookie_consent
    return if cookie_consent_given?

    request.session_options[:skip] = true
    reset_session
  end

  def cookie_consent_given?
    cookies[:cookie_consent] == "accepted"
  end
end
