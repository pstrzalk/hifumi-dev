class CookieConsentsController < ApplicationController
  # Accept must work before the user has consent — that's the whole point.
  skip_before_action :enforce_cookie_consent

  # CSRF tokens live in the session. Without consent the session is skipped,
  # so the token rendered on a prior page wouldn't match anything on this
  # POST. Acceptable to skip: a forged consent only sets a cookie the user
  # could have set themselves by accepting the banner — the worst case is a
  # benign auto-accept the user can undo by clicking "Review cookie settings"
  # → Decline.
  skip_before_action :verify_authenticity_token, only: :create

  def create
    cookies[:cookie_consent] = {
      value:     "accepted",
      expires:   1.year.from_now,
      same_site: :lax,
      secure:    Rails.env.production?,
      httponly:  true,
      path:      "/"
    }
    redirect_to safe_referer
  end

  private

  def safe_referer
    referer = request.referer
    return root_path unless referer

    uri = URI.parse(referer)
    return root_path unless uri.host.nil? || uri.host == request.host
    referer
  rescue URI::InvalidURIError
    root_path
  end
end
