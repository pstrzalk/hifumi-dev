import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button"]

  static CONSENT_KEY = "cookieConsent"

  connect() {
    // Initial state from localStorage in case cookie_consent_controller's
    // `cookie-consent-changed` event has already fired before we connect.
    this.applyConsent(localStorage.getItem(this.constructor.CONSENT_KEY))

    this.boundHandleConsentChanged = this.handleConsentChanged.bind(this)
    window.addEventListener("cookie-consent-changed", this.boundHandleConsentChanged)
  }

  disconnect() {
    window.removeEventListener("cookie-consent-changed", this.boundHandleConsentChanged)
  }

  handleConsentChanged(event) {
    this.applyConsent(event.detail.consent)
  }

  // Banner is visible when consent is null → hide the button (redundant).
  // Banner is hidden when consent is "declined" → show the button.
  // ("accepted" never reaches here because the form would render instead.)
  applyConsent(consent) {
    if (consent === null) {
      this.hideButton()
    } else {
      this.showButton()
    }
  }

  requestReopen() {
    window.dispatchEvent(new CustomEvent("cookie-consent-reopen"))
  }

  showButton() {
    if (this.hasButtonTarget) this.buttonTarget.classList.remove("is-hidden")
  }

  hideButton() {
    if (this.hasButtonTarget) this.buttonTarget.classList.add("is-hidden")
  }
}
