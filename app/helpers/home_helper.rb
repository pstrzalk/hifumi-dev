module HomeHelper
  # Dashboard quick actions. With at least one project: a prominent link to
  # the most-recently-active project plus a muted link to the full list.
  # With none: a single call to action to start the first project.
  def dashboard_actions(recent_project)
    if recent_project
      safe_join([
        link_to("open #{recent_project.name} ↗", project_path(recent_project), class: "dash-cta"),
        link_to("all projects ↗", projects_path, class: "dash-link")
      ])
    else
      link_to "start your first project ↗", new_project_path, class: "dash-cta"
    end
  end
end
