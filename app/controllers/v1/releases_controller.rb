module V1
  # Public JSON reads have no browser, session or importmap callbacks.
  class ReleasesController < ActionController::API
    rescue_from ReleaseService::InvalidSha1, with: :invalid_sha1
    rescue_from ReleaseService::ReleaseNotFound, with: :release_not_found

    before_action :set_release
    before_action :answer_not_modified

    def show
      render json: ReleaseDecorator.decorate(@release)
    end

    private
      def set_release
        @release = ReleaseService.find_by(sha1: params[:sha1].to_s)
      end

      # The ETag comes from the records' updated_at and the decorator's VERSION,
      # so it changes with the data and with the JSON shape. A client with a
      # fresh copy gets a 304 and the action never runs.
      def answer_not_modified
        expires_in 300, public: true
        fresh_when(etag: [ ReleaseDecorator::VERSION, @release, @release.game ], public: true)
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
