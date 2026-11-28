if Rails.env.production?
  asset_build = defined?(Rake.application) && Rake.application.top_level_tasks == [ "assets:precompile" ]
  if !asset_build && ENV["SECRET_KEY_BASE"].to_s.strip.empty?
    raise "Production runtime requires a nonblank environment SECRET_KEY_BASE"
  end

  Rails.application.config.secret_key_base = ENV["SECRET_KEY_BASE"] unless asset_build
end
