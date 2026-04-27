module PreviewsHelper
  def preview_pane_partial(project)
    case project.preview_state.to_sym
    when :stopped, nil then "previews/stopped"
    when :starting     then "previews/starting"
    when :running      then "previews/running"
    when :failed       then "previews/failed"
    end
  end
end
