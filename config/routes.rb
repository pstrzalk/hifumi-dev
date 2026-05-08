Rails.application.routes.draw do
  devise_for :users,
    controllers: {
      registrations: "users/registrations",
      omniauth_callbacks: "users/omniauth_callbacks"
    }

  resource :github_connection, only: :destroy

  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"

  resources :projects, only: [ :index, :new, :create, :show, :destroy ] do
    resources :messages, only: [ :create ]
    resource  :preview,  only: [ :create, :destroy ]
    resource  :github_export, only: [ :create, :destroy ]
  end
end
