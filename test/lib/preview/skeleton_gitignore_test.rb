require "test_helper"

class Preview::SkeletonGitignoreTest < ActiveSupport::TestCase
  SKELETON_GITIGNORE = Rails.root.join("lib/preview/skeleton/.gitignore")

  setup do
    @contents = SKELETON_GITIGNORE.read
  end

  test "ignores /vendor/bundle/ (incident fix: hifumi.dev 2026-05-11)" do
    assert_match(%r{^/vendor/bundle/$}, @contents)
  end

  test "ignores /node_modules/" do
    assert_match(%r{^/node_modules/$}, @contents)
  end

  test "ignores /.yarn/cache/" do
    assert_match(%r{^/\.yarn/cache/$}, @contents)
  end

  test "ignores /.yarn/install-state.gz" do
    assert_match(%r{^/\.yarn/install-state\.gz$}, @contents)
  end

  test "ignores /app/assets/builds/*" do
    assert_match(%r{^/app/assets/builds/\*$}, @contents)
  end

  test "preserves /app/assets/builds/.keep so the directory survives a fresh clone" do
    assert_match(%r{^!/app/assets/builds/\.keep$}, @contents)
  end
end
