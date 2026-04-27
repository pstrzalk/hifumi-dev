Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#new"

  resources :projects, only: [ :new, :create, :show ] do
    resources :messages, only: [ :create ]
    resource  :preview,  only: [ :create, :destroy ]
  end
end
