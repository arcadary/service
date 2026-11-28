Rails.application.routes.draw do
  mount ->(env) { McpTransportService.call(env: env) }, at: "/mcp"

  scope "v1", module: "v1", format: false, defaults: { format: :json }, constraints: { sha1: /[^\/]+/ } do
    get "playthrough-stages/:staging_id.json", to: "playthrough_stages#show"
    put "playthrough-stages/:staging_id/objects/:stage_object_id.json", to: "playthrough_stages#update"
    post "screenshot-stages/:release_id/:source_sha1/:kind.json", to: "screenshot_stages#create", constraints: { release_id: /[^\/]+/, source_sha1: /[^\/]+/, kind: /[^\/]+/ }
    get "lookup/:sha1.json", to: "lookups#show", as: :lookup
    get "releases/:sha1.json", to: "releases#show", as: :release
    get "media/:sha1.json", to: "media#show", as: :media
    put "releases/:sha1/screenshots/:kind.json", to: "screenshot_uploads#update", constraints: { kind: /[^\/]+/ }
  end
  get "v1/screenshots/:sha256.png", to: "v1/screenshots#show", format: false, constraints: { sha256: /[^\/]+/ }

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
