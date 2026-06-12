require "shellwords"

module Templates
  module Picker
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a frontend template picker. Given a user's plain-language project description, pick the single best-fit template from this fixed list:

      - cyber  — dark, neon, terminal/cyberpunk feel, monospace, sharp corners
      - flower — pastel, soft, decorative; suits boutiques, lifestyle, wellness, weddings
      - earth  — muted, warm, low-contrast; suits journals, blogs, slow-living, content
      - office — clean professional like Jira/Linear; suits dashboards, internal tools, B2B
      - kids   — bright, playful, bold borders; suits children's apps, games, learning, fun

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
      content = chat.with_schema(SCHEMA).ask("Description: #{description}").content
      name = content.is_a?(Hash) ? content["template"] : nil
      raise InvalidPick, "picker returned #{content.inspect}" unless Templates::NAMES.include?(name)
      name
    end

    def self.apply(workspace:, name:)
      tpl = Templates.find(name)

      frontend_path = File.join(workspace, "docs/frontend.md")
      FileUtils.mkdir_p(File.dirname(frontend_path))
      File.write(frontend_path, tpl.frontend_md)

      layout_path = File.join(workspace, "app/views/layouts/application.html.erb")
      layout = File.read(layout_path)
      raise "layout missing </head>" unless layout.include?("</head>")
      File.write(layout_path, layout.sub("</head>", "    #{tpl.fonts_html.strip}\n  </head>"))

      ok = system(
        "cd #{Shellwords.escape(workspace)} && git add docs/frontend.md app/views/layouts/application.html.erb && " \
        "git -c user.email=#{Shellwords.escape(Project::COMMIT_AUTHOR_EMAIL)} " \
        "-c user.name=#{Shellwords.escape(Project::COMMIT_AUTHOR_NAME)} " \
        "commit -q -m 'docs: pick frontend template (#{name})'"
      )
      raise "git commit failed in #{workspace}" unless ok
    end
  end
end
