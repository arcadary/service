module V1
  # Public JSON reads have no browser, session or importmap callbacks.
  class ReleasesController < ActionController::API
    # The API does not inherit ApplicationController (its browser and importmap
    # callbacks would refuse the launcher), so it includes the shared concern.
    include ConditionalGet

    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :release_not_found

    before_action :set_release
    # The ETag changes with the release, its game and the JSON shape.
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
