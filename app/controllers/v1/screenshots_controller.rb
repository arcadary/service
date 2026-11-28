module V1
  class ScreenshotsController < ApiController
    rescue_from Screenshot::NotFound, with: -> { render_error("screenshot_not_found", status: :not_found) }

    before_action :set_png

    def show
      expires_in 31_536_000, public: true
      send_data @png, type: "image/png", disposition: "inline"
    end

    private
      def set_png
        @png = ScreenshotService.find_by(sha256: params[:sha256].to_s)
      end
  end
end
