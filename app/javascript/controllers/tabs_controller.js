import { Controller } from "@hotwired/stimulus"

// Single-root tabs controller. Toggles `display: none` on pane elements
// and an `is-active` class on tab buttons. No URL state, no localStorage.
//
// Implements the WAI-ARIA tabs pattern
// (https://www.w3.org/WAI/ARIA/apg/patterns/tabs/):
//   - `aria-selected` and roving `tabindex` reflect the active tab
//   - Left/Right/Home/End arrow keys cycle focus through tab buttons
//   - panes carry role="tabpanel" + aria-labelledby (set in show.html.erb)
export default class extends Controller {
  static targets = ["tab", "pane"]
  static values = { active: { type: String, default: "build" } }

  connect() {
    this.render()
  }

  switch(event) {
    const name = event.currentTarget.dataset.tabName
    if (!name) return
    this.activeValue = name
    event.currentTarget.focus()
  }

  keydown(event) {
    const tabs = this.tabTargets
    const idx = tabs.indexOf(event.currentTarget)
    if (idx < 0) return

    let nextIdx = null
    switch (event.key) {
      case "ArrowLeft":  nextIdx = (idx - 1 + tabs.length) % tabs.length; break
      case "ArrowRight": nextIdx = (idx + 1) % tabs.length; break
      case "Home":       nextIdx = 0; break
      case "End":        nextIdx = tabs.length - 1; break
      default: return
    }
    event.preventDefault()
    const next = tabs[nextIdx]
    this.activeValue = next.dataset.tabName
    next.focus()
  }

  activeValueChanged() {
    this.render()
  }

  render() {
    const active = this.activeValue
    this.tabTargets.forEach((el) => {
      const isActive = el.dataset.tabName === active
      el.classList.toggle("is-active", isActive)
      el.setAttribute("aria-selected", isActive ? "true" : "false")
      el.setAttribute("tabindex", isActive ? "0" : "-1")
    })
    this.paneTargets.forEach((el) => {
      el.style.display = (el.dataset.tabName === active) ? "" : "none"
    })
  }
}
