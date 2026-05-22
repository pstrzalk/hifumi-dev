module ProjectsHelper
  # The project's derived build state as a Hifumi status tag. GENERATING is a
  # live state, so it carries the blinking dot (mirrors revisions/_revision).
  # Used on the projects list and the project page header.
  def project_state_tag(project)
    state = project.build_state
    dot = state == :generating ? content_tag(:span, "", class: "tag-dot") : "".html_safe
    content_tag(:span, safe_join([ dot, state.to_s ]), class: "tag tag--#{state}")
  end
end
