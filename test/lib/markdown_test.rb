require "test_helper"

class MarkdownTest < ActiveSupport::TestCase
  # Every construct this suite feeds the renderer, reused by the standing
  # invariants at the bottom — no anchors, no inline styles, no spans, ever.
  SAMPLES = [
    "**bold**",
    "*italics*",
    "1. **A** first\n\n2. **B** second",
    "- one\n- two",
    "use `x = 1` here",
    "```ruby\ndef x\n  1\nend\n```",
    "### Plan",
    "~~gone~~",
    "> quoted",
    "| a | b |\n|---|---|\n| 1 | 2 |",
    "- [ ] todo\n- [x] done",
    ":tada:",
    "<script>alert(1)</script>",
    %q{<img src=x onerror=alert(1)>},
    "![x](https://example.com/a.png)",
    "[click](https://example.com)",
    "[click](javascript:alert(1))",
    "https://example.com/plain",
    %q{<p style="color:red" onclick="alert(1)">x</p>},
    "<style>body{display:none}</style>"
  ].freeze

  # --- Rendering -----------------------------------------------------------

  test "bold becomes strong" do
    assert_equal "<p><strong>hi</strong></p>\n", Markdown.render("**hi**")
  end

  test "italics become em" do
    assert_equal "<p><em>hi</em></p>\n", Markdown.render("*hi*")
  end

  # The shape the chat agent actually produces: blank line between items, which
  # makes the list loose and wraps each item's content in <p>.
  test "loose ordered list wraps items in p" do
    html = Markdown.render("1. **A** first\n\n2. **B** second")

    assert_match %r{<ol>}, html
    assert_match %r{<li>\s*<p><strong>A</strong> first</p>\s*</li>}, html
    assert_match %r{<li>\s*<p><strong>B</strong> second</p>\s*</li>}, html
  end

  test "bullets become ul and li" do
    assert_equal "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n", Markdown.render("- one\n- two")
  end

  test "inline code becomes code" do
    assert_equal "<p>use <code>x = 1</code> here</p>\n", Markdown.render("use `x = 1` here")
  end

  # <pre> is the block marker the CSS keys on — verify it survives the allowlist
  # at top level, and that the info string's lang attribute does not.
  test "fenced code renders as pre wrapping code" do
    assert_equal "<pre><code>def x\n  1\nend\n</code></pre>\n",
                 Markdown.render("```ruby\ndef x\n  1\nend\n```")
  end

  # The case position alone cannot detect: a child of <li>, neither a child of
  # the body nor nested in a <p>.
  test "fenced code inside a list item also renders as pre wrapping code" do
    html = Markdown.render("1. do:\n\n   ```\n   x = 1\n   y = 2\n   ```")

    assert_match %r{<li>.*<pre><code>x = 1\ny = 2\n</code></pre>.*</li>}m, html
  end

  # Guards render.hardbreaks — the current look depends on single newlines
  # surviving as <br>.
  test "single newlines survive as br" do
    assert_equal "<p>a<br>\nb</p>\n", Markdown.render("a\nb")
  end

  test "blank input renders empty and html_safe" do
    [ nil, "", "   " ].each do |blank|
      rendered = Markdown.render(blank)

      assert_equal "", rendered
      assert_predicate rendered, :html_safe?
    end
  end

  test "rendered output is html_safe" do
    assert_predicate Markdown.render("**hi**"), :html_safe?
  end

  # --- Flattening (the minimal-allowlist contract) -------------------------

  test "heading renders as plain text with no h3 and no anchor" do
    html = Markdown.render("### Plan")

    assert_includes html, "Plan"
    refute_includes html, "<h3"
    refute_includes html, "<a"
  end

  test "strikethrough markers are consumed and the text kept" do
    html = Markdown.render("~~gone~~")

    assert_includes html, "gone"
    refute_includes html, "~~"
    refute_includes html, "<del"
  end

  test "blockquote flattens to a paragraph" do
    html = Markdown.render("> quoted")

    assert_includes html, "<p>quoted</p>"
    refute_includes html, "<blockquote"
  end

  # Guards extension.table = false. With the extension on, stripping the table
  # tags jams every cell together as "a\nb\n\n\n\n\n1\n2".
  test "table stays literal pipe characters" do
    html = Markdown.render("| a | b |\n|---|---|\n| 1 | 2 |")

    assert_includes html, "| a | b |"
    assert_includes html, "| 1 | 2 |"
    refute_includes html, "<table"
  end

  # Guards extension.tasklist = false. Consuming the markers would make done
  # and todo indistinguishable once <input> is stripped.
  test "task list keeps its literal markers and emits no input element" do
    html = Markdown.render("- [ ] todo\n- [x] done")

    assert_includes html, "[ ] todo"
    assert_includes html, "[x] done"
    refute_includes html, "<input"
  end

  # Guards extension.shortcodes = false. By sanitize time an emoji is a text
  # node, so the sanitizer could not undo the substitution.
  test "emoji shortcode stays literal" do
    assert_includes Markdown.render(":tada:"), ":tada:"
  end

  # --- Safety --------------------------------------------------------------

  test "script tag is removed" do
    html = Markdown.render("<script>alert(1)</script>")

    refute_includes html, "<script"
    refute_includes html, "alert(1)"
  end

  test "img with onerror is removed" do
    html = Markdown.render(%q{<img src=x onerror=alert(1)>})

    refute_includes html, "<img"
    refute_includes html, "onerror"
  end

  test "markdown image is dropped" do
    html = Markdown.render("![x](https://example.com/a.png)")

    refute_includes html, "<img"
    refute_includes html, "example.com"
  end

  test "markdown link keeps its label and emits no anchor" do
    html = Markdown.render("[click](https://example.com)")

    assert_includes html, "click"
    refute_includes html, "<a"
    refute_includes html, "href"
  end

  test "javascript href never appears" do
    [
      "[click](javascript:alert(1))",
      %q{<a href="jav&#x09;ascript:alert(1)">click</a>}
    ].each do |source|
      html = Markdown.render(source)

      refute_includes html, "javascript"
      refute_includes html, "href"
    end
  end

  test "entity-smuggled script stays escaped text" do
    html = Markdown.render("&lt;script&gt;alert(1)&lt;/script&gt;")

    assert_includes html, "&lt;script&gt;"
    refute_includes html, "<script"
  end

  test "style and onclick attributes are stripped" do
    html = Markdown.render(%q{<p style="color:red" onclick="alert(1)">x</p>})

    refute_includes html, "style"
    refute_includes html, "onclick"
  end

  # Layer 2 alone would strip the <style> tag but leave the CSS as visible text;
  # layer 1 (unsafe: false) omits the whole element first.
  test "style element contents do not leak as text" do
    refute_includes Markdown.render("<style>body{display:none}</style>"), "display:none"
  end

  test "fence info string cannot inject an attribute" do
    html = Markdown.render(%Q{```"><script>alert(1)</script>\nx\n```})

    assert_equal "<pre><code>x\n</code></pre>\n", html
  end

  # --- Standing invariants over every sample -------------------------------

  # Guards plugins.syntax_highlighter — the default injects
  # style="background-color:#2b303b" and <span style="color:#...">.
  test "output never contains an inline style or a span" do
    SAMPLES.each do |source|
      html = Markdown.render(source)

      refute_includes html, "style=", "inline style survived for #{source.inspect}"
      refute_includes html, "<span", "span survived for #{source.inspect}"
    end
  end

  # The no-links decision: no allowlisted <a>, no autolink extension, no
  # post-pass. Nothing may produce an anchor.
  test "output never contains an anchor tag" do
    SAMPLES.each do |source|
      refute_includes Markdown.render(source), "<a", "anchor survived for #{source.inspect}"
    end
  end
end
