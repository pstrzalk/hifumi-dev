import { Controller } from "@hotwired/stimulus"

// Watches an end-of-conversation sentinel. While the sentinel is in the
// viewport, the conversation is at-bottom: hide the jump button. When the
// sentinel leaves the viewport (user scrolled up, or new content pushed it
// out of view), show the button. Click → smooth-scroll to the sentinel.
//
// Also auto-follows new bubbles/streamed chunks via a MutationObserver on
// #messages, but only while atBottom — preserving scroll position when the
// user has scrolled up.
export default class extends Controller {
  static targets = ["sentinel", "jumpButton"]

  connect() {
    // Start false: the IO callback fires asynchronously after observe(), so
    // there is a brief window between connect() and the first callback. A
    // broadcast arriving in that window with atBottom = true would auto-scroll
    // a user who didn't intend to follow (e.g. landing mid-stream on a long
    // chat). Defaulting false errs on the side of "do nothing" — the IO will
    // flip it true within ~16ms if the sentinel is genuinely in view.
    this.atBottom = false
    this.messagesElement = this.element.querySelector("#messages")
    this.followFrame = null

    // rootMargin: shrinks the IO viewport's bottom by 20px. Tiny shrink so
    //   (a) at max page scroll the sentinel — which sits ~78px above viewport
    //       bottom because the sticky dock is in front of it — still
    //       intersects (atBottom = true, auto-follow fires).
    //   (b) once the user scrolls up by ~60px (sentinel.top crosses the -20px
    //       line), atBottom flips to false and the jump button shows.
    // Keep the magnitude smaller than the dock height (~78px) — otherwise
    // atBottom is false even at max scroll. The button is absolutely
    // positioned so its visibility no longer changes dock height (avoids a
    // per-frame oscillation between IO toggles).
    this.intersectionObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        this.atBottom = entry.isIntersecting
        if (this.hasJumpButtonTarget) {
          this.jumpButtonTarget.hidden = entry.isIntersecting
        }
      }
    }, { root: null, threshold: 0, rootMargin: "0px 0px -20px 0px" })
    if (this.hasSentinelTarget) this.intersectionObserver.observe(this.sentinelTarget)

    if (this.messagesElement) {
      this.mutationObserver = new MutationObserver(() => this.scheduleFollow())
      // childList only — broadcasts append/replace whole message partials.
      // characterData would fire on every text-node mutation inside an
      // existing partial; broadcast_replace_message swaps the partial wholesale,
      // so characterData adds noise (and cost during streaming) without signal.
      this.mutationObserver.observe(this.messagesElement, {
        childList: true,
        subtree: true,
      })
    }
  }

  disconnect() {
    if (this.intersectionObserver) this.intersectionObserver.disconnect()
    if (this.mutationObserver) this.mutationObserver.disconnect()
    if (this.followFrame) cancelAnimationFrame(this.followFrame)
  }

  jumpToEnd() {
    if (this.hasSentinelTarget) {
      this.sentinelTarget.scrollIntoView({ behavior: "smooth", block: "end" })
    }
  }

  // Coalesce a burst of mutations (e.g. several streaming chunks landing in
  // the same frame) into a single scrollIntoView call.
  scheduleFollow() {
    if (this.followFrame) return
    this.followFrame = requestAnimationFrame(() => {
      this.followFrame = null
      this.followIfAtBottom()
    })
  }

  followIfAtBottom() {
    if (!this.atBottom) return
    if (!this.hasSentinelTarget) return
    this.sentinelTarget.scrollIntoView({ behavior: "auto", block: "end" })
  }
}
