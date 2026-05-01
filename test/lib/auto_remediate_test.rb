require "test_helper"
require Rails.root.join("lib/roast/auto_remediate")

class AutoRemediateTest < ActiveSupport::TestCase
  test "no match: returns empty array, no shell calls" do
    with_shell_stub(->(_ws, _cmd) { flunk("shell should not be called when no recipe matches") }) do
      result = AutoRemediate.run("/tmp/ws", "some unrelated test failure")
      assert_equal [], result
    end
  end

  test "matches bundler missing gems error and runs bundle install" do
    captured_workspace = nil
    captured_cmd = nil
    with_shell_stub(->(ws, cmd) { captured_workspace = ws; captured_cmd = cmd; true }) do
      errors = "GemNotFound: Could not find puma-8.0.1 in locally installed gems"
      result = AutoRemediate.run("/tmp/my-ws", errors)

      assert_equal 1, result.size
      assert_match(/bundler missing gems: ran `bundle install`/, result.first)
      assert_equal "/tmp/my-ws", captured_workspace
      assert_includes captured_cmd, "bundle install --jobs 4"
    end
  end

  test "matches the human-friendly bundle check error message too" do
    with_shell_stub(->(_ws, _cmd) { true }) do
      errors = "The following gems are missing\n * puma (8.0.1)\nInstall missing gems with `bundle install`"
      result = AutoRemediate.run("/tmp/ws", errors)
      assert_equal 1, result.size
    end
  end

  test "matches master.key permission error and restores from git" do
    captured_cmd = nil
    with_shell_stub(->(_ws, cmd) { captured_cmd = cmd; true }) do
      errors = "error: open(\"config/master.key\"): Permission denied"
      result = AutoRemediate.run("/tmp/ws", errors)

      assert_equal 1, result.size
      assert_match(/restored config\/master\.key/, result.first)
      assert_includes captured_cmd, "git checkout HEAD -- config/master.key"
    end
  end

  test "shell command failure swallows the recipe so we fall through to the LLM" do
    with_shell_stub(->(_ws, _cmd) { false }) do
      result = AutoRemediate.run("/tmp/ws", "Bundler::GemNotFound")
      assert_equal [], result, "failed shell -> nil from fix proc -> not in applied list"
    end
  end

  test "multiple matching recipes all run" do
    calls = 0
    with_shell_stub(->(_ws, _cmd) { calls += 1; true }) do
      errors = "Bundler::GemNotFound\nopen(\"config/master.key\"): Permission denied"
      result = AutoRemediate.run("/tmp/ws", errors)
      assert_equal 2, result.size
      assert_equal 2, calls
    end
  end

  private

  def with_shell_stub(stub_proc)
    AutoRemediate.singleton_class.alias_method(:__orig_shell, :shell)
    AutoRemediate.define_singleton_method(:shell) { |ws, cmd| stub_proc.call(ws, cmd) }
    yield
  ensure
    AutoRemediate.singleton_class.alias_method(:shell, :__orig_shell)
    AutoRemediate.singleton_class.send(:remove_method, :__orig_shell)
  end
end
