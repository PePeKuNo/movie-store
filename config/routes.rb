Rails.application.routes.draw do
  root "home#index"

  namespace :api do
    get "meta",            to: "meta#index"
    get "movies",          to: "movies#index"
    get "export",          to: "export#index"
    get "export/progress", to: "export#progress"

    get "trailers/:key/status", to: "trailers#status", as: :trailer_status
    get "trailers/:key/plan",   to: "trailers#plan",   as: :trailer_plan
    get "trailers/:key/poster", to: "trailers#poster", as: :trailer_poster
    get "trailers/:key/video",  to: "trailers#video",  as: :trailer_video
  end

  # Rails 8 ships a health endpoint that does not touch the (absent) database.
  get "up", to: "rails/health#show", as: :rails_health_check
end
