class StopPreviewJob < ApplicationJob
  queue_as :preview

  def perform(project_id)
    project = Project.find(project_id)
    Preview::PreviewManager.new.stop(project)
  end
end
