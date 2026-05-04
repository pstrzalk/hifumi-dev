# frozen_string_literal: true

# Single-revision modification plan used by the integration test for the
# design-tweak flow. Mirrors the shape PlanApplicationModification would
# produce for a small styling change ("make the banner green").

module PlanFixtures
  def self.banner_green
    PlanApplicationModification::Result.new(
      instruction_description: "Change the top banner to green.",
      revisions: [
        {
          summary: "Update banner color in application layout",
          prompt: "In app/views/layouts/application.html.erb, change the banner background color from yellow to green. Verify by inspecting the rendered class on the banner element."
        }
      ]
    )
  end
end
