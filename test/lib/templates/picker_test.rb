require "test_helper"

class Templates::PickerTest < ActiveSupport::TestCase
  # --- pick: LLM stubbed via mock on the chat object -------------------

  test "pick returns the name when LLM responds with a known template" do
    stub_pick("cyber") do
      assert_equal "cyber", Templates::Picker.pick(description: "neon hacker tracker", openrouter_api_key: "sk-test", model: "anthropic/claude-haiku-4.5")
    end
  end

  test "pick raises InvalidPick when LLM returns an unknown name" do
    stub_pick("brutalist") do
      assert_raises(Templates::Picker::InvalidPick) do
        Templates::Picker.pick(description: "x", openrouter_api_key: "sk-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "pick raises InvalidPick when LLM returns nil/non-hash content" do
    stub_pick(nil) do
      assert_raises(Templates::Picker::InvalidPick) do
        Templates::Picker.pick(description: "x", openrouter_api_key: "sk-test", model: "anthropic/claude-haiku-4.5")
      end
    end
  end

  test "pick passes the selected model to the chat" do
    stub_pick("cyber") do |captured|
      Templates::Picker.pick(description: "x", openrouter_api_key: "sk-test", model: "anthropic/claude-opus-4.6")
      assert_equal "anthropic/claude-opus-4.6", captured[:chat_kwargs][:model]
    end
  end

  # --- apply: workspace side effects -----------------------------------

  test "apply writes docs/frontend.md with the template's content" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "cyber")
      written = File.read(File.join(ws, "docs/frontend.md"))
      assert_equal Templates.find("cyber").frontend_md, written
    end
  end

  test "apply injects fonts.html before </head> in the layout" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "flower")
      layout = File.read(File.join(ws, "app/views/layouts/application.html.erb"))
      assert_match %r{fonts\.googleapis\.com}, layout
      assert_match %r{</head>}, layout, "must keep </head> intact"
      head_idx = layout.index("</head>")
      flower_idx = layout.index("Quicksand") || layout.index("fonts.googleapis.com")
      assert flower_idx < head_idx, "fonts must be injected BEFORE </head>"
    end
  end

  test "apply raises when layout has no </head> tag" do
    in_workspace do |ws|
      File.write(File.join(ws, "app/views/layouts/application.html.erb"), "<html><body></body></html>")
      assert_raises(RuntimeError) { Templates::Picker.apply(workspace: ws, name: "earth") }
    end
  end

  test "apply commits both files with the expected message" do
    in_workspace do |ws|
      Templates::Picker.apply(workspace: ws, name: "office")
      msg = `cd #{Shellwords.escape(ws)} && git log -1 --pretty=%s`.strip
      assert_equal "docs: pick frontend template (office)", msg

      changed = `cd #{Shellwords.escape(ws)} && git show --name-only --pretty=format: HEAD`.split("\n").reject(&:empty?).sort
      assert_equal %w[app/views/layouts/application.html.erb docs/frontend.md], changed
    end
  end

  # --- helpers ---------------------------------------------------------

  private

  # Build a minimal git-initialized workspace with the layout file present.
  def in_workspace
    Dir.mktmpdir("templates-picker-test-") do |ws|
      FileUtils.mkdir_p(File.join(ws, "app/views/layouts"))
      File.write(
        File.join(ws, "app/views/layouts/application.html.erb"),
        "<!DOCTYPE html>\n<html>\n  <head>\n    <title>x</title>\n  </head>\n  <body></body>\n</html>"
      )
      Dir.chdir(ws) do
        system("git init -q && git add -A && " \
               "git -c user.email=t@t -c user.name=t commit -q -m baseline")
      end
      yield ws
    end
  end

  # Replace RubyLLM.context for the duration of the block. The fake context
  # mirrors the real chain (`chat → with_instructions → with_schema → ask
  # → content`) so Templates::Picker.pick exercises its real code path,
  # only the LLM endpoint is swapped. Minitest 6 dropped Object#stub, so we
  # use the same singleton-method-swap pattern as verify_revision_test.rb.
  def stub_pick(value)
    fake_content = value.nil? ? nil : { "template" => value, "reasoning" => "stub" }
    fake_chat = Object.new
    fake_chat.define_singleton_method(:with_instructions) { |_| self }
    fake_chat.define_singleton_method(:with_schema)       { |_| self }
    fake_chat.define_singleton_method(:ask)               { |_| Struct.new(:content).new(fake_content) }

    captured = {}
    fake_ctx = Object.new
    fake_ctx.define_singleton_method(:chat) do |**kwargs|
      captured[:chat_kwargs] = kwargs
      fake_chat
    end

    RubyLLM.singleton_class.alias_method(:__orig_context, :context)
    RubyLLM.define_singleton_method(:context) { |&_blk| fake_ctx }
    yield captured
  ensure
    RubyLLM.singleton_class.alias_method(:context, :__orig_context)
    RubyLLM.singleton_class.send(:remove_method, :__orig_context)
  end
end
