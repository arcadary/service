Rails.application.routes.draw do
  mount ->(env) { McpTransportService.call(env: env) }, at: "/mcp"

  scope "v1", module: "v1", format: false, defaults: { format: :json }, constraints: { sha1: /[^\/]+/ } do
    get "uploads/:upload_id.json", to: "uploads#show", constraints: { upload_id: /[^\/]+/ }
    put "uploads/:upload_id/files/*name", to: "uploads#update", constraints: { upload_id: /[^\/]+/, name: /.+/ }
    get "lookup/:sha1.json", to: "lookups#show", as: :lookup
    get "releases/:sha1.json", to: "releases#show", as: :release
    get "media/:sha1.json", to: "media#show", as: :media
  end

  mount Rswag::Ui::Engine => "/api-docs"
  mount Rswag::Api::Engine => "/api-docs"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
end
