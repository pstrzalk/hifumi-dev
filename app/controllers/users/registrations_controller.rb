class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [:create]
  before_action :configure_account_update_params, only: [:update]

  def new
    build_resource({})
    resource.build_profile
    respond_with resource
  end

  def update
    attrs = params.dig(:user, :profile_attributes)
    if attrs && attrs[:openrouter_api_key].blank?
      attrs.delete(:openrouter_api_key)
    end
    super
  end

  private

  def configure_sign_up_params
    devise_parameter_sanitizer.permit(:sign_up,
      keys: [profile_attributes: [:first_name, :last_name, :openrouter_api_key]])
  end

  def configure_account_update_params
    devise_parameter_sanitizer.permit(:account_update,
      keys: [profile_attributes: [:id, :first_name, :last_name, :openrouter_api_key]])
  end
end
