module V1
  class ReleasesController < ActionController::API
    include ConditionalGet

    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :release_not_found

    before_action :set_release
    before_action -> { answer_not_modified(etag: [ ReleaseDecorator::VERSION, @release, @release.game ]) }

    def show
      render json: ReleaseDecorator.decorate(@release)
    end

    private
      def set_release
        @release = ReleaseService.find_by(sha1: params[:sha1].to_s)
      end

      def invalid_sha1
        lookup_error("invalid_sha1", :bad_request)
      end

      def release_not_found
        lookup_error("release_not_found", :not_found)
      end

      def lookup_error(error, status)
        response.headers["Cache-Control"] = "no-store"
        render json: { error: error }, status: status
      end
  end
end
