Rails.application.routes.draw do
  namespace :v1 do
    resources :accounts, only: [] do
      resources :withdrawals, only: [:create]
    end
  end
end
