import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["banner"]

  static CONSENT_KEY = "cookieConsent"
  static CONSENT_ACCEPTED = "accepted"
  static CONSENT_DECLINED = "declined"

  connect() {
    const consent = this.getConsent()
    if (consent === null) {
      this.showBanner()
    } else {
      this.hideBanner()
    }
    this.dispatchConsentStatus(consent)

    this.boundReopen = this.reopen.bind(this)
    window.addEventListener("cookie-consent-reopen", this.boundReopen)
  }

  disconnect() {
    window.removeEventListener("cookie-consent-reopen", this.boundReopen)
  }

  accept(event) {
    // Mirror to localStorage so the banner stays hidden on subsequent
    // client-side renders even before the redirected page lands.
    localStorage.setItem(this.constructor.CONSENT_KEY, this.constructor.CONSENT_ACCEPTED)
    this.hideBanner()
    this.dispatchConsentStatus(this.constructor.CONSENT_ACCEPTED)
    // Let the <form action="/cookie_consent" method="post"> submit normally;
    // the server sets the Secure;HttpOnly cookie and redirects to the referer.
    // No event.preventDefault().
  }

  decline() {
    localStorage.setItem(this.constructor.CONSENT_KEY, this.constructor.CONSENT_DECLINED)
    this.hideBanner()
    this.dispatchConsentStatus(this.constructor.CONSENT_DECLINED)
  }

  getConsent() {
    return localStorage.getItem(this.constructor.CONSENT_KEY)
  }

  showBanner() {
    if (this.hasBannerTarget) this.bannerTarget.classList.remove("is-hidden")
  }

  hideBanner() {
    if (this.hasBannerTarget) this.bannerTarget.classList.add("is-hidden")
  }

  dispatchConsentStatus(status) {
    window.dispatchEvent(new CustomEvent("cookie-consent-changed", {
      detail: { consent: status, accepted: status === this.constructor.CONSENT_ACCEPTED }
    }))
  }

  reopen() {
    localStorage.removeItem(this.constructor.CONSENT_KEY)
    this.showBanner()
  }
}
