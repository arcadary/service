class PlaythroughStageBody
  def initialize(app)
    @app = app
  end

  def call(env)
    path = Rack::Utils.unescape_path(env.fetch("PATH_INFO")).b.gsub(%r{/+}, "/")
    if %r{\A/v1/playthrough-stages(?:[/.]|\z)}.match?(path)
      env["action_dispatch.request.request_parameters"] = {}
    end
    @app.call(env)
  end
end
