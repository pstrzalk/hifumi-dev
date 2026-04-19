import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["textarea"]

  prefill(event) {
    this.textareaTarget.value = event.params.value
    this.textareaTarget.focus()
  }

  prefillMessage(event) {
    const input = document.getElementById("message_content_input")
    if (!input) return
    input.value = event.params.value
    input.focus()
  }
}
