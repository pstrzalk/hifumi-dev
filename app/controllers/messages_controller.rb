class MessagesController < ApplicationController
  def create
    @project = Project.find(params[:project_id])
    content = message_params[:content].to_s.strip

    if content.blank?
      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace(ActionView::RecordIdentifier.dom_id(@project, :message_form), partial: "messages/form", locals: { project: @project }), status: :unprocessable_entity }
        format.html { redirect_to @project, alert: "Message cannot be blank." }
      end
      return
    end

    message = @project.chat.messages.create!(role: :user, content: content)
    ChatRespondJob.perform_later(message.id)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace(ActionView::RecordIdentifier.dom_id(@project, :message_form), partial: "messages/form", locals: { project: @project }) }
      format.html { redirect_to @project }
    end
  end

  private

  def message_params
    params.require(:message).permit(:content)
  end
end
