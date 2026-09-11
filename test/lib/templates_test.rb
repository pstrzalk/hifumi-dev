require "test_helper"

class TemplatesTest < ActiveSupport::TestCase
  test "all five templates load with non-empty frontend.md and fonts.html" do
    Templates::NAMES.each do |name|
      tpl = Templates.find(name)
      assert_equal name, tpl.name
      assert_predicate tpl.frontend_md, :present?, "#{name} frontend.md must be non-empty"
      assert_predicate tpl.fonts_html,  :present?, "#{name} fonts.html must be non-empty"
    end
  end

  test "every frontend.md contains the canonical sections" do
    required = [ "## Vibe", "## Class snippets", "## Fonts" ]
    Templates::NAMES.each do |name|
      md = Templates.find(name).frontend_md
      required.each do |section|
        assert_includes md, section, "#{name}/frontend.md must have a '#{section}' section"
      end
    end
  end

  test "every fonts.html references fonts.googleapis.com" do
    Templates::NAMES.each do |name|
      assert_match %r{fonts\.googleapis\.com}, Templates.find(name).fonts_html,
                   "#{name}/fonts.html must reference fonts.googleapis.com"
    end
  end

  # frontend.md is in the W2 manifest on every revision — every line is a
  # per-revision token cost. Warn at 30 if too thin; cap to stop drift.
  #
  # Raised 100 -> 115 on 2026-09-11 for the `## Images` section. The old cap was
  # sized for five component snippets (button, field, card, shell, alert); images
  # are a sixth category, not drift. Measured cost of the addition: ~1 000 chars,
  # ~260 tokens per revision, against a ~9 300-char implementer prompt. Raise this
  # again only for another whole category, never to fit more of the same.
  test "every frontend.md is between 30 and 115 lines" do
    Templates::NAMES.each do |name|
      lines = Templates.find(name).frontend_md.lines.size
      assert_operator lines, :<=, 115, "#{name}/frontend.md is #{lines} lines — cap is 115"
      assert_operator lines, :>=, 30,  "#{name}/frontend.md is #{lines} lines — looks too thin"
    end
  end

  # The code agent styled photos by improvisation before this section existed:
  # production project 50 shipped `rounded-lg` headshots into the office
  # template, whose every other snippet is `rounded-sm`, plus four identical
  # `alt: "Placeholder portrait"` strings. Each template now carries its own
  # image treatment, so assert the pieces the agent actually needs are present.
  test "every frontend.md has an Images section with band, portrait and card guidance" do
    Templates::NAMES.each do |name|
      md = Templates.find(name).frontend_md
      assert_includes md, "## Images",           "#{name} is missing the Images section"
      assert_includes md, "### Hero band",       "#{name} is missing the hero band snippet"
      assert_includes md, "### Portrait / avatar", "#{name} is missing the portrait snippet"
      assert_includes md, "### Image card",      "#{name} is missing the image card snippet"
    end
  end

  # The three shipped aspect ratios: 1600x900, 1600x1600, 1067x1600. An agent
  # that guesses these crops faces off headshots.
  test "every Images section names the real aspect ratios and forbids placeholder alt text" do
    Templates::NAMES.each do |name|
      md = Templates.find(name).frontend_md
      assert_includes md, "aspect-[2/3]",  "#{name} must pin headshots to 2:3"
      assert_includes md, "aspect-square", "#{name} must pin card images to 1:1"
      assert_includes md, "object-cover",  "#{name} must say object-cover"
      # Prose wraps; assert on the sentence, not on where the line breaks fall.
      prose = md.gsub(/\s+/, " ")
      assert_includes prose, 'never "Placeholder"', "#{name} must warn off placeholder alt text"
      assert_includes prose, "full absolute URL",   "#{name} must require the absolute URL"
    end
  end

  # Each template's image treatment must speak that template's own visual
  # language — the whole point of doing this per template rather than once in
  # the photo inventory. The radius is the tell: office mandates rounded-sm and
  # got rounded-lg from the agent unaided.
  test "each template's image snippets use that template's own radius" do
    { "cyber" => "rounded-none", "office" => "rounded-sm", "earth" => "rounded-md",
      "flower" => "rounded-2xl", "kids" => "rounded-2xl" }.each do |name, radius|
      images = Templates.find(name).frontend_md.split("## Images").last
      assert_includes images, radius, "#{name}/frontend.md Images section should use #{radius}"
    end
  end

  test "find raises ArgumentError for unknown name" do
    assert_raises(ArgumentError) { Templates.find("brutalist") }
    assert_raises(ArgumentError) { Templates.find("") }
  end

  test "known? returns false for blank or unknown names" do
    refute Templates.known?("")
    refute Templates.known?(nil)
    refute Templates.known?("brutalist")
    Templates::NAMES.each { |n| assert Templates.known?(n) }
  end
end
