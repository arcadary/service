module V1
  class ScreenshotUploadsController < ApiController
    rescue_from Screenshot::UploadsDisabled, with: -> { render_error("uploads_disabled", status: :service_unavailable) }
    rescue_from Screenshot::Unauthorized, with: -> { render_error("unauthorized", status: :unauthorized) }
    rescue_from Screenshot::InvalidKind, Screenshot::InvalidImage, with: -> { render_error("invalid_screenshot", status: :unprocessable_content) }
    rescue_from Screenshot::TooLarge, with: -> { render_error("screenshot_too_large", status: :content_too_large) }
    rescue_from Screenshot::StorageUnavailable, with: -> { render_error("storage_unavailable", status: :service_unavailable) }
    rescue_from Release::InvalidSha1, with: -> { render_error("invalid_sha1", status: :bad_request) }
    rescue_from Release::ReleaseNotFound, with: -> { render_error("release_not_found", status: :not_found) }
    rescue_from Release::AmbiguousRelease, with: -> { render_error("ambiguous_release", status: :conflict) }

    before_action :disable_caching
    before_action :require_capture_token
    before_action :set_release
    before_action :set_screenshot

    def update
      render json: ScreenshotDecorator.decorate(@screenshot)
    end

    private
      def disable_caching
        response.headers["Cache-Control"] = "no-store"
      end

      def require_capture_token
        ScreenshotConfigurationService.authenticate!(authorization: request.authorization)
      end

      def set_release
        @release = ReleaseService.find_by(sha1: params[:sha1].to_s)
      end

      def set_screenshot
        @screenshot = ScreenshotService.create(release: @release, kind: params[:kind].to_s, io: request.body, content_type: request.media_type)
      end
  end
end
