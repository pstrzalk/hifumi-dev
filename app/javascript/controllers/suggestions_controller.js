import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

  prefill(event) {
    this.textareaTarget.value = event.params.value
    this.textareaTarget.focus()
  }
}
