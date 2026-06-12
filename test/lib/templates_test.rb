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
  # per-revision token cost. Cap at 100 to stop drift; warn at 30 if too thin.
  test "every frontend.md is between 30 and 100 lines" do
    Templates::NAMES.each do |name|
      lines = Templates.find(name).frontend_md.lines.size
      assert_operator lines, :<=, 100, "#{name}/frontend.md is #{lines} lines — cap is 100"
      assert_operator lines, :>=, 30,  "#{name}/frontend.md is #{lines} lines — looks too thin"
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
