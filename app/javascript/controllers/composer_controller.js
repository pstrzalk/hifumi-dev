import { Controller } from "@hotwired/stimulus"

// Composer behaviors:
//   - connect():     focus the textarea (restores cursor after Turbo stream form-replace,
//                    since the HTML autofocus attribute does not re-fire on stream replace)
//   - resize():      on input, set rows = clamp(min, newline-count, max)
//   - submit():      on keydown, ⌘/Ctrl+Enter requestSubmit()s the form
export default class extends Controller {
  static targets = ["input"]
  static values  = { minRows: { type: Number, default: 2 },
                     maxRows: { type: Number, default: 5 } }

  connect() {
    if (this.hasInputTarget) this.inputTarget.focus()
    this.resize()
  }

  resize() {
    if (!this.hasInputTarget) return
    const lines = this.inputTarget.value.split("\n").length
    const clamped = Math.max(this.minRowsValue, Math.min(this.maxRowsValue, lines))
    this.inputTarget.rows = clamped
  }

  submit(event) {
    if (event.key !== "Enter") return
    if (!(event.metaKey || event.ctrlKey)) return
    // Ignore Enter while an IME is composing (CJK input, some dead-key layouts):
    // the keypress is "commit composition", not "submit". keyCode 229 is the
    // legacy fallback for browsers that don't expose isComposing on the event.
    if (event.isComposing || event.keyCode === 229) return
    event.preventDefault()
    this.element.requestSubmit()
  }
}
