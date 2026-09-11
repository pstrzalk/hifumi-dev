require "shellwords"

module Templates
  module Picker
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a frontend template picker. Given a user's plain-language project description, pick the single best-fit template from this fixed list:

      - cyber     — dark, neon, terminal/cyberpunk feel, monospace, sharp corners
      - flower    — pastel, soft, decorative; suits boutiques, lifestyle, wellness, weddings
      - earth     — muted, warm, low-contrast; suits journals, blogs, slow-living, content
      - office    — clean professional like Jira/Linear; suits the INSIDE of a tool: dashboards, admin, B2B apps
      - kids      — bright, playful, bold borders; suits children's apps, games, learning, fun
      - launch    — modern product landing page, gradient accent, big headlines; suits marketing sites, startups, waitlists, "promote X" — the page in FRONT of a product, where office is the app behind it
      - luxe      — ivory, light serif, hairline rules, lots of space; suits hotels, restaurants, jewellery, property, high-end retail — expensive and restrained, where flower is soft and sweet
      - editorial — black on white, heavy serif headlines, column rules; suits magazines, news, reviews, publications — high-contrast and reported, where earth is quiet and personal

      If nothing fits cleanly, pick the closest. Never invent names. Output exactly the JSON schema requested.
    PROMPT

    SCHEMA = {
      "type" => "object",
      "additionalProperties" => false,
      "required" => [ "template", "reasoning" ],
      "properties" => {
        "template"  => { "type" => "string", "enum" => Templates::NAMES },
        "reasoning" => { "type" => "string", "maxLength" => 200 }
      }
    }.freeze

    class InvalidPick < StandardError; end

    def self.call(workspace:, description:, openrouter_api_key:, model:)
      name = pick(description: description, openrouter_api_key: openrouter_api_key, model: model)
      apply(workspace: workspace, name: name)
      name
    end

    def self.pick(description:, openrouter_api_key:, model:)
      ctx = RubyLLM.context { |c| c.openrouter_api_key = openrouter_api_key }
      chat = ctx.chat(model: model)
      chat.with_instructions(SYSTEM_PROMPT)
      response = chat.with_schema(SCHEMA).ask("Description: #{description}")
      # Scoped to `.parsed` alone: RubyLLM decodes provider error bodies as JSON
      # too, so a method-wide rescue would relabel an OpenRouter 502 that returns
      # an HTML page as "picker returned malformed JSON" and send whoever reads
      # the failed revision to the prompt instead of the transport.
      content = begin
        response.parsed
      rescue JSON::ParserError => e
        raise InvalidPick, "picker returned malformed JSON: #{e.message}"
      end
      name = content.is_a?(Hash) ? content["template"] : nil
      raise InvalidPick, "picker returned #{content.inspect}" unless Templates::NAMES.include?(name)
      name
    end

    # The templates' snippets use `font-display` and expect the body face from
    # `fonts.html` to apply, but nothing ever defined either: Tailwind 4 resolves
    # `font-display` from a `--font-display` theme token, and the skeleton's
    # application.css is a bare `@import "tailwindcss"`. So every generated app
    # downloaded its typeface and rendered in system sans — project 51 used
    # `font-display` 18 times and its built CSS never mentioned Space Grotesk.
    #
    # Written here rather than asked of the agent because an instruction can be
    # forgotten and this one demonstrably was. lib/preview/Dockerfile runs
    # `tailwindcss:build`, so the block reaches the preview container's CSS.
    THEME_MARKER = "/* hifumi:template-theme */"

    def self.apply_theme(workspace:, theme_css:)
      path = File.join(workspace, "app/assets/tailwind/application.css")
      raise "tailwind application.css missing in #{workspace}" unless File.exist?(path)

      # Idempotent: drop any block this method wrote before, then append.
      base = File.read(path).split(THEME_MARKER).first.rstrip
      File.write(path, "#{base}\n\n#{THEME_MARKER}\n#{theme_css.strip}\n")
    end

    def self.apply(workspace:, name:)
      tpl = Templates.find(name)

      frontend_path = File.join(workspace, "docs/frontend.md")
      FileUtils.mkdir_p(File.dirname(frontend_path))
      File.write(frontend_path, tpl.frontend_md)

      apply_theme(workspace: workspace, theme_css: tpl.theme_css)

      layout_path = File.join(workspace, "app/views/layouts/application.html.erb")
      layout = File.read(layout_path)
      raise "layout missing </head>" unless layout.include?("</head>")
      File.write(layout_path, layout.sub("</head>", "    #{tpl.fonts_html.strip}\n  </head>"))

      ok = system(
        "cd #{Shellwords.escape(workspace)} && " \
        "git add docs/frontend.md app/views/layouts/application.html.erb app/assets/tailwind/application.css && " \
        "git -c user.email=#{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} " \
        "-c user.name=#{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} " \
        "commit -q -m 'docs: pick frontend template (#{name})'"
      )
      raise "git commit failed in #{workspace}" unless ok
    end
  end
end
