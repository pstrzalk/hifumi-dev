# frozen_string_literal: true

require "vips"

# The curated photo set in public/photos/, rendered as a prompt section.
#
# Shaped like lib/templates.rb — module, Struct, root, memoized — with one
# deliberate divergence: this file MUST NOT touch Rails. lib/roast/revision_workflow.rb
# requires it by path so RevisionPrompt can render the same inventory, and that
# runs under `bundle exec roast` with no environment.rb, so there is no Rails
# constant and no Rails.application.config. Both root and base_url resolve
# without one. A stray Rails.root here breaks every revision in the sandbox
# while dev stays green.
#
# Adding a photo is copy-a-file-and-deploy: drop a slug-named .jpg into
# public/photos/, add a row to public/photos/CREDITS.md, deploy. Dimensions and
# orientation are derived from the file, never encoded in the name — encoded
# geometry drifts the moment someone re-exports an image.
module Photos
  # The filename is the only hand-maintained metadata AND it is rendered
  # verbatim into three LLM system prompts, so it is validated on every read
  # rather than trusted. Lowercase, digits, single hyphens.
  SLUG = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

  DEFAULT_BASE_URL = "http://localhost:3000"

  Photo = Struct.new(:slug, :filename, :width, :height, keyword_init: true) do
    def orientation
      return "square" if width == height
      width > height ? "landscape" : "portrait"
    end

    def url = "#{Photos.base_url}/photos/#{filename}"

    def to_line = "- #{filename} — #{width}×#{height}, #{orientation}"
  end

  class << self
    # Memoized per process. public/ is baked into the image, so adding a photo
    # already requires a deploy, and a deploy is a restart.
    def all
      @all ||= Dir.glob(File.join(root, "*.jpg")).sort.filter_map { |path| build(path) }
    end

    # Rendered into both planner system prompts and the W2.1 implementer prompt.
    # Memoized for the same reason as `all`: it is re-rendered on every planner
    # call and every revision, and its inputs only change on deploy.
    #
    # The wording carries a scope decision (2026-09-11): the set exists for
    # page-level chrome and will never cover per-record artwork. Rather than let
    # the agent discover that by running out of images, name the intended use,
    # name the alternative for the case the set cannot serve, and forbid
    # inventing a URL — which is what production project 46 did
    # (https://example.com/photos/ada.jpg) with no list in front of it.
    def prompt_section
      @prompt_section ||= <<~SECTION.chomp
        ## Photos available

        Royalty-free photos hosted at #{base_url}/photos/, listed in full below.
        Reference them by absolute URL, in a view or in seeds.

        Use them for page-level imagery: a homepage hero, a section band, an about
        or team page. This is the complete set, and there is no per-record artwork
        in it — for anything that repeats per row (a catalogue, a library, a
        listing) style the cards with CSS and markup instead. Never write an image
        URL that is not in this list.

        #{all.map(&:to_line).join("\n")}
      SECTION
    end

    # NOT Rails.root — see the note at the top of this file. __dir__ is lib/,
    # and public/photos sits beside it both in the repo and in the image.
    def root = @root || File.expand_path("../public/photos", __dir__)

    # Test seam. Resets the memos so a fixture directory takes effect.
    attr_writer :root

    def with_root(path)
      previous = @root
      self.root = path
      reset!
      yield
    ensure
      @root = previous
      reset!
    end

    def reset!
      @all = nil
      @prompt_section = nil
    end

    # Not Rails.application.config either: ExecuteInstructionJob forwards
    # PHOTOS_BASE_URL into the sandbox by name, so the Rails process and the
    # roast subprocess read one and the same ENV var.
    def base_url = ENV.fetch("PHOTOS_BASE_URL", DEFAULT_BASE_URL)

    private

    # nil rather than raise for anything unreadable — one corrupt file must not
    # take down every planner call, the same reasoning as AppState.read_workspace_file
    # (lib/app_state.rb:89-95) — and nil for anything that fails SLUG, so a stray
    # upload can never inject text into a system prompt.
    def build(path)
      filename = File.basename(path)
      slug = File.basename(path, ".jpg")
      return nil unless slug.match?(SLUG)

      image = Vips::Image.new_from_file(path)
      Photo.new(slug: slug, filename: filename, width: image.width, height: image.height)
    rescue Vips::Error
      nil
    end
  end
end
