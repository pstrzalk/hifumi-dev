import { Controller } from "@hotwired/stimulus"

// Mobile navigation drawer.
// Below 640px the hamburger toggle is visible; clicking it opens a
// right-sliding panel containing every nav link that isn't the brand or
// the Sign up CTA. Esc, backdrop click, and the close button all
// dismiss. Focus moves into the panel on open and back to the toggle
// on close. Body scroll is locked while the drawer is open.
export default class extends Controller {
  static targets = ["toggle", "drawer"]

  open() {
    this.drawerTarget.hidden = false
    this.toggleTarget.setAttribute("aria-expanded", "true")
    document.body.style.overflow = "hidden"
    const firstLink = this.drawerTarget.querySelector(".app-nav-drawer__close")
    if (firstLink) firstLink.focus()
  }

  close() {
    this.drawerTarget.hidden = true
    this.toggleTarget.setAttribute("aria-expanded", "false")
    document.body.style.overflow = ""
    this.toggleTarget.focus()
  }

  backdropClick(event) {
    // Only close on a click that hit the backdrop itself, not a child.
    if (event.target === this.drawerTarget) this.close()
  }

  keydown(event) {
    if (this.drawerTarget.hidden) return
    if (event.key === "Escape") {
      event.preventDefault()
      this.close()
    }
  }
}
