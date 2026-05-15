require "test_helper"

class WorkspaceAuthorshipTest < ActiveSupport::TestCase
  test "init_rails_app sets repo-local user.email/name to hifumi.dev identity" do
    Dir.mktmpdir("hifumi-dev-authorship-") do |root|
      ws = File.join(root, "project_authorship")
      ExecuteInstructionJob.new.send(:init_rails_app, ws)

      email = `git -C #{Shellwords.escape(ws)} config user.email`.strip
      name  = `git -C #{Shellwords.escape(ws)} config user.name`.strip

      assert_equal "code@hifumi.dev", email
      assert_equal "hifumi.dev",      name
    end
  end

  test "init_rails_app's first commit is authored as hifumi.dev <code@hifumi.dev>" do
    Dir.mktmpdir("hifumi-dev-authorship-commit-") do |root|
      ws = File.join(root, "project_authorship_commit")
      ExecuteInstructionJob.new.send(:init_rails_app, ws)

      sha = `git -C #{Shellwords.escape(ws)} rev-parse HEAD`.strip
      assert_match(/\A[0-9a-f]{40}\z/, sha, "init_rails_app must produce a real first commit")

      author = `git -C #{Shellwords.escape(ws)} log -1 --pretty='%an <%ae>' #{sha}`.strip
      assert_equal "hifumi.dev <code@hifumi.dev>", author
    end
  end

  test "init_rails_app pins initial branch to main regardless of host init.defaultBranch" do
    Dir.mktmpdir("hifumi-dev-authorship-branch-") do |root|
      ws = File.join(root, "project_authorship_branch")
      ExecuteInstructionJob.new.send(:init_rails_app, ws)

      branch = `git -C #{Shellwords.escape(ws)} rev-parse --abbrev-ref HEAD`.strip
      assert_equal "main", branch
    end
  end
end
