require "test_helper"

class PhotosTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/photos").to_s

  setup { Photos.reset! }
  teardown { Photos.reset! }

  # ---- loading ----

  test "all returns one Photo per valid jpg, sorted by slug" do
    Photos.with_root(FIXTURES) do
      assert_equal %w[landscape-fixture portrait-fixture square-fixture], Photos.all.map(&:slug)
    end
  end

  test "orientation is derived from the pixels, not the name" do
    Photos.with_root(FIXTURES) do
      by_slug = Photos.all.index_by(&:slug)
      assert_equal "landscape", by_slug["landscape-fixture"].orientation
      assert_equal "portrait",  by_slug["portrait-fixture"].orientation
      assert_equal "square",    by_slug["square-fixture"].orientation
    end
  end

  # A zero-byte .jpg is in the fixtures under a name that also fails SLUG, so
  # this covers both rejection paths at once: neither raises.
  test "a filename that fails SLUG is skipped, not raised on" do
    Photos.with_root(FIXTURES) do
      assert_not_includes Photos.all.map(&:filename), "Not A Slug.jpg"
    end
  end

  test "a non-jpg file in the directory is ignored" do
    Photos.with_root(FIXTURES) do
      assert_not_includes Photos.all.map(&:filename), "CREDITS.md"
    end
  end

  test "an unreadable jpg yields nil rather than taking down the whole set" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(FIXTURES, "square-fixture.jpg"), dir)
      File.write(File.join(dir, "corrupt-fixture.jpg"), "not a jpeg at all")

      Photos.with_root(dir) do
        assert_equal %w[square-fixture], Photos.all.map(&:slug)
      end
    end
  end

  # ---- urls ----

  test "url uses PHOTOS_BASE_URL when set" do
    with_env("PHOTOS_BASE_URL" => "https://hifumi.dev") do
      Photos.with_root(FIXTURES) do
        assert_equal "https://hifumi.dev/photos/square-fixture.jpg",
                     Photos.all.find { |p| p.slug == "square-fixture" }.url
      end
    end
  end

  test "url falls back to the dev default when PHOTOS_BASE_URL is unset" do
    with_env("PHOTOS_BASE_URL" => nil) do
      Photos.with_root(FIXTURES) do
        assert_equal "http://localhost:3000/photos/square-fixture.jpg",
                     Photos.all.find { |p| p.slug == "square-fixture" }.url
      end
    end
  end

  # ---- prompt section ----

  test "prompt_section lists every photo with its geometry and orientation" do
    Photos.with_root(FIXTURES) do
      section = Photos.prompt_section
      assert_includes section, "- landscape-fixture.jpg — 120×60, landscape"
      assert_includes section, "- portrait-fixture.jpg — 60×120, portrait"
      assert_includes section, "- square-fixture.jpg — 90×90, square"
    end
  end

  # The sentences that stop the agent inventing https://example.com/photos/ada.jpg
  # (production project 46) and that encode the page-level scope decision.
  test "prompt_section states the set is complete and names the alternative" do
    Photos.with_root(FIXTURES) do
      # The heredoc hard-wraps, so assert on the prose rather than on where the
      # line breaks fall — re-wrapping the paragraph is not a regression.
      prose = Photos.prompt_section.gsub(/\s+/, " ")
      assert_includes prose, "This is the complete set"
      assert_includes prose, "Never write an image URL that is not in this list."
      assert_includes prose, "style the cards with CSS and markup instead"
    end
  end

  test "prompt_section uses the configured base url" do
    with_env("PHOTOS_BASE_URL" => "https://hifumi.dev") do
      Photos.with_root(FIXTURES) do
        assert_includes Photos.prompt_section, "https://hifumi.dev/photos/"
      end
    end
  end

  # Both planner system prompts are guarded by this regex
  # (test/services/plan_application_*/ad_hoc_llm_test.rb:56). The photo section
  # is appended to those prompts at the call site, outside the guard's reach, so
  # assert it here instead.
  test "prompt_section trips none of the planner prompt guards" do
    guard = /devise|pundit|cancancan|sidekiq|rspec|spec\/|factory_bot|factorybot|simplecov|--accent|--paper|--ink|propshaft|importmap|solid_/i

    Photos.with_root(FIXTURES) { refute_match guard, Photos.prompt_section }
    refute_match guard, Photos.prompt_section
  end

  # ---- memoization ----

  test "all is memoized — a second call returns the same objects" do
    Photos.with_root(FIXTURES) do
      assert_same Photos.all, Photos.all
    end
  end

  test "prompt_section is memoized" do
    Photos.with_root(FIXTURES) do
      assert_same Photos.prompt_section, Photos.prompt_section
    end
  end

  # ---- Rails-free: the constraint the Roast subprocess depends on ----

  # lib/roast/revision_workflow.rb requires this file by path under
  # `bundle exec roast`, where environment.rb never runs. A Rails.root or a
  # Rails.application.config here would raise NameError inside the sandbox on
  # every revision while dev stayed green, so load it in a bare Ruby process.
  test "the module loads and renders with no Rails constant in the process" do
    script = <<~RUBY
      raise "Rails is defined" if defined?(Rails)
      require #{Rails.root.join('lib/photos').to_s.inspect}
      Photos.root = #{FIXTURES.inspect}
      print Photos.prompt_section
    RUBY

    out = nil
    Bundler.with_unbundled_env do
      out = `cd #{Shellwords.escape(Rails.root.to_s)} && bundle exec ruby -e #{Shellwords.escape(script)} 2>&1`
    end

    assert_predicate $?, :success?, "bare-Ruby load failed:\n#{out}"
    assert_includes out, "- square-fixture.jpg — 90×90, square"
  end

  # ---- the real directory ----

  # Deliberately not a count: adding a photo is meant to be copy-a-file-and-deploy,
  # and a test pinned to 31 would make it copy-a-file-and-edit-a-test.
  test "the shipped set loads and every entry has real geometry" do
    assert_predicate Photos.all, :any?, "public/photos/ should not be empty"

    Photos.all.each do |photo|
      assert_operator photo.width, :>, 0, "#{photo.slug} has no width"
      assert_operator photo.height, :>, 0, "#{photo.slug} has no height"
      assert_match Photos::SLUG, photo.slug
    end
  end

  private

  def with_env(vars)
    previous = vars.keys.index_with { |key| ENV[key] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Photos.reset!
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Photos.reset!
  end
end
