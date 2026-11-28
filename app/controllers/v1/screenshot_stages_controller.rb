module V1
  class ScreenshotStagesController < ApiController
    rescue_from Screenshot::UploadsDisabled, with: -> { render_error("uploads_disabled", status: :service_unavailable) }
    rescue_from Screenshot::InvalidImage, with: -> { render_error("invalid_screenshot", status: :unprocessable_content) }
    rescue_from Screenshot::TooLarge, with: -> { render_error("screenshot_too_large", status: :content_too_large) }
    rescue_from Screenshot::StorageUnavailable, with: -> { render_error("storage_unavailable", status: :service_unavailable) }
    rescue_from ScreenshotStage::InvalidInput, with: -> { render_error("invalid_input", status: :bad_request) }
    rescue_from ScreenshotStage::TargetMismatch, with: -> { render_error("target_mismatch", status: :conflict) }
    rescue_from Release::ReleaseNotFound, with: -> { render_error("not_found", status: :not_found) }

    before_action :set_stage

    def create
      render json: ScreenshotStageDecorator.decorate(@stage), status: :created
    end

    private
      def set_stage
        @stage = ScreenshotStagingService.create(release_id: params[:release_id].to_s, source_sha1: params[:source_sha1].to_s,
          kind: params[:kind].to_s, io: request.body, content_type: request.media_type)
      end
  end
end
