# Renders LLM-authored chat text as a small, deliberately safe subset of HTML.
#
# TWO LAYERS, both required — do not "simplify" by dropping either:
#
#   1. Commonmarker with render.unsafe = false. Raw HTML in the source is replaced
#      by an "<!-- raw HTML omitted -->" placeholder instead of being passed
#      through, and javascript:/data:/vbscript: URLs are emptied by the parser.
#   2. Rails::HTML5::SafeListSanitizer over an explicit allowlist.
#
# Layer 2 alone is NOT enough: given <style>body{display:none}</style> it strips
# the tag but leaves the CSS text visible. Layer 1 omits it first. Layer 1 alone is
# not enough either — it is one config flag away from unsafe: true.
#
# This matters more than usual here: config/initializers/content_security_policy.rb
# sets script_src to :self, :https with no strict-dynamic, so ANY https origin is an
# allowed script source. CSP will not stop an injected <script src="https://...">;
# escaping is the only defense.
module Markdown
  # Commonmarker 2.9.0 defaults that are wrong for us, each verified by running it:
  #   - a syntax highlighter is ON, injecting style="background-color:#2b303b" and
  #     <span style="color:#..."> — hardcoded hex (against the design system) that
  #     the sanitizer strips again anyway  -> plugins.syntax_highlighter = nil
  #   - header_ids is ON, wrapping every heading in an <a class="anchor">  -> nil
  #   - tasklist is ON, emitting <input type="checkbox">  -> false
  #   - shortcodes is ON, turning :tada: into an emoji. By sanitize time that is a
  #     text node, so the sanitizer cannot undo it, and the design system has no
  #     emoji in the chat surface  -> false
  #
  # hardbreaks is NOT a wrong default — it is already true in 2.9.0. It is set
  # explicitly to pin it, because the current look (single newlines rendered by
  # white-space: pre-wrap) depends on those newlines surviving as <br>.
  #
  # table is OFF deliberately. The sanitizer keeps a stripped tag's children, so
  # leaving it ON and dropping <table>/<tr>/<td> jams every cell together as
  # "a\nb\n\n\n\n\n1\n2". OFF leaves readable literal | pipes instead.
  #
  # strikethrough is ON so commonmarker consumes the ~~ markers; the sanitizer then
  # drops <del> and keeps the text. autolink is OFF because we render no anchors.
  #
  # tagfilter is ON but inert as configured: it escapes raw <script>/<style>/
  # <iframe> into text, and unsafe: false already omits all raw HTML before it
  # gets a chance (verified: <script>alert(1)</script> -> "<!-- raw HTML omitted
  # -->"). It stays as a third guard on the one flag this file warns about — if
  # unsafe ever flips to true, the worst tags are still escaped rather than live.
  OPTIONS = {
    render: { unsafe: false, hardbreaks: true },
    extension: {
      header_ids: nil,
      tasklist: false,
      table: false,
      autolink: false,
      strikethrough: true,
      shortcodes: false,
      tagfilter: true
    }
  }.freeze

  PLUGINS = { syntax_highlighter: nil }.freeze

  # Minimal on purpose. Anything not listed loses its tag but keeps its text, so
  # headings, blockquotes and strikethrough flatten to plain prose. Omitting <img>
  # is what drops markdown images; omitting <a> is what drops links.
  #
  # <pre> is here because it is the only reliable marker for "this code is a block
  # rather than a span": a fence inside a list item lands as a child of <li>, so
  # position cannot tell the two apart. It carries no attributes past ATTRIBUTES
  # (lang="ruby" is stripped), so allowing it adds no attack surface.
  TAGS = %w[p br strong em code pre ul ol li].freeze

  # No attributes at all — nothing in TAGS needs one.
  ATTRIBUTES = [].freeze

  SANITIZER = Rails::HTML5::SafeListSanitizer.new

  def self.render(text)
    return "".html_safe if text.blank?

    html = Commonmarker.to_html(text.to_s, options: OPTIONS, plugins: PLUGINS)
    SANITIZER.sanitize(html, tags: TAGS, attributes: ATTRIBUTES).to_s.html_safe
  end
end
