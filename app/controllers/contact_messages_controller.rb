class ContactMessagesController < ApplicationController
  def new
    @contact_message = ContactMessage.new
  end

  def create
    @contact_message = ContactMessage.new(contact_message_params)

    if @contact_message.save
      redirect_to thanks_contact_path
    else
      render :new, status: :unprocessable_entity
    end
  end

  def thanks
  end

  private

  def contact_message_params
    params.require(:contact_message).permit(:email, :message)
  end
end
