class PlaythroughStageBody
  def initialize(app)
    @app = app
  end

  def call(env)
    path = Rack::Utils.unescape_path(env.fetch("PATH_INFO")).b.gsub(%r{/+}, "/")
    if %r{\A/v1/playthrough-stages(?:[/.]|\z)}.match?(path)
      env["action_dispatch.request.request_parameters"] = {}
      if env["REQUEST_METHOD"] == "PUT"
        target = %r{\A/v1/playthrough-stages/([^/]+)/objects/([^/]+)\.json\z}.match(path)
        PlaythroughUploadAuthorizationService.authorize!(capability: env["HTTP_X_ARCADARY_UPLOAD_CAPABILITY"],
          staging_id: target&.[](1), object_id: target&.[](2))
      end
    end
    @app.call(env)
  rescue PlaythroughStage::UploadNotAuthorized
    [ 403, { "content-type" => "application/json", "cache-control" => "no-store" }, [ { error: "upload_not_authorized" }.to_json ] ]
  end
end
