require "test_helper"

class StopPreviewJobTest < ActiveJob::TestCase
  setup do
    @project = Project.create!(name: "Preview Stop Job Test", user: users(:owner))
  end

  test "uses :preview queue" do
    assert_enqueued_with(job: StopPreviewJob, args: [ @project.id ], queue: "preview") do
      StopPreviewJob.perform_later(@project.id)
    end
  end

  test "delegates to Preview::PreviewManager#stop with the right project" do
    captured = nil
    fake = Class.new do
      define_method(:initialize) { }
      define_method(:stop) { |project| captured = project }
    end

    Preview::PreviewManager.singleton_class.alias_method(:_orig_new, :new)
    Preview::PreviewManager.define_singleton_method(:new) { |*| fake.new }
    begin
      StopPreviewJob.perform_now(@project.id)
    ensure
      Preview::PreviewManager.singleton_class.alias_method(:new, :_orig_new)
      Preview::PreviewManager.singleton_class.send(:remove_method, :_orig_new)
    end

    assert_equal @project.id, captured.id
  end
end
