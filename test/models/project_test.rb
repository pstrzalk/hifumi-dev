require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "valid fixture loads" do
    assert projects(:flowers).valid?
  end

  test "requires name" do
    project = Project.new
    assert_not project.valid?
    assert_includes project.errors[:name], "can't be blank"
  end

  test "workspace_path is under workspace_root with project_ prefix" do
    project = projects(:flowers)
    assert_equal File.join(Project.workspace_root, "project_#{project.id}"), project.workspace_path
  end

  test "workspace_initialized? returns false when no Gemfile in workspace" do
    project = Project.create!(name: "Uninitialized", user: users(:owner))
    assert_not project.workspace_initialized?
  end

  test "workspace_initialized? returns true when Gemfile exists in workspace" do
    project = Project.create!(name: "Initialized", user: users(:owner))
    ws = project.workspace_path
    FileUtils.mkdir_p(ws)
    File.write(File.join(ws, "Gemfile"), "source 'https://rubygems.org'\n")
    assert project.workspace_initialized?
  ensure
    FileUtils.rm_rf(ws) if ws
  end

  test "workspace_root honors HIFUMI_DEV_WORKSPACE_ROOT env var" do
    original = ENV["HIFUMI_DEV_WORKSPACE_ROOT"]
    ENV["HIFUMI_DEV_WORKSPACE_ROOT"] = "/tmp/custom_ws_root"
    assert_equal "/tmp/custom_ws_root", Project.workspace_root
  ensure
    ENV["HIFUMI_DEV_WORKSPACE_ROOT"] = original
  end

  test "has one chat and many instructions/revisions" do
    project = projects(:flowers)
    assert_equal chats(:flowers), project.chat
    assert_includes project.instructions, instructions(:flowers_v1)
    assert_equal 2, project.revisions.count
  end

  test "destroying project cascades to chat, instructions, revisions" do
    project = projects(:flowers)
    assert_difference -> { Chat.count } => -1,
                      -> { Instruction.count } => -1,
                      -> { Revision.count } => -2 do
      project.destroy!
    end
  end

  # --- preview state ----------------------------------------------------

  test "preview_state defaults to :stopped" do
    project = Project.create!(name: "fresh", user: users(:owner))
    assert_equal "stopped", project.preview_state
    assert project.preview_stopped?
  end

  test "preview_port is 3000 + id" do
    project = projects(:flowers)
    assert_equal 3000 + project.id, project.preview_port
  end

  test "preview_url returns nil unless preview_state == :running" do
    project = projects(:flowers)
    %w[stopped starting failed].each do |state|
      project.update!(preview_state: state)
      assert_nil project.preview_url, "expected preview_url to be nil when state=#{state}"
    end
  end

  test "preview_url returns http://localhost:<3000 + id> when running" do
    project = projects(:flowers)
    project.update!(preview_state: :running)
    assert_equal "http://localhost:#{3000 + project.id}", project.preview_url
  end

  test "preview_url returns https://<id>.preview.<domain> when Preview::Config.remote?" do
    project = projects(:flowers)
    project.update!(preview_state: :running)
    original = Rails.configuration.preview.domain
    Rails.configuration.preview.domain = "hifumi.dev"
    assert_equal "https://#{project.id}.preview.hifumi.dev", project.preview_url
  ensure
    Rails.configuration.preview.domain = original
  end

  # --- build state ------------------------------------------------------

  test "build_state is :new for a project with no instructions" do
    project = Project.create!(name: "Fresh", user: users(:owner))
    assert_equal :new, project.build_state
  end

  test "build_state is :generating when the latest instruction is not terminal" do
    project = project_with_chat
    add_instruction(project, phase: :implementing)
    assert_equal :generating, project.build_state
  end

  test "build_state is :failed when the latest instruction failed" do
    project = project_with_chat
    add_instruction(project, phase: :failed)
    assert_equal :failed, project.build_state
  end

  test "build_state is :ready when the latest instruction completed" do
    project = project_with_chat
    add_instruction(project, phase: :completed)
    assert_equal :ready, project.build_state
  end

  test "build_state follows the latest instruction — a newer failure overrides an older completion" do
    project = project_with_chat
    add_instruction(project, phase: :completed, created_at: 2.hours.ago)
    add_instruction(project, phase: :failed, created_at: 1.hour.ago)
    assert_equal :failed, project.build_state
  end

  test "build_state breaks identical-created_at ties by id — the higher-id instruction decides" do
    project = project_with_chat
    same_time = 1.hour.ago
    add_instruction(project, phase: :completed, created_at: same_time)
    add_instruction(project, phase: :failed, created_at: same_time)
    assert_equal :failed, project.build_state
  end

  private

  def project_with_chat
    project = Project.create!(name: "Buildable", user: users(:owner))
    project.create_chat!
    project
  end

  def add_instruction(project, phase:, created_at: nil)
    message = project.chat.messages.create!(role: :user, content: "do a thing")
    attrs = { user_intent: "x", description: "x", phase: phase, anchor_message: message }
    attrs[:created_at] = created_at if created_at
    project.instructions.create!(attrs)
  end
end
