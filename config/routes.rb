Rails.application.routes.draw do
  devise_for :users, controllers: { registrations: "users/registrations" }
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#new"

  resources :projects, only: [ :index, :new, :create, :show, :destroy ] do
    resources :messages, only: [ :create ]
    resource  :preview,  only: [ :create, :destroy ]
  end
end
