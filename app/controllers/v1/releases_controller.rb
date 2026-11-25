module V1
  # Public JSON reads have no browser, session or importmap callbacks.
  class ReleasesController < ActionController::API
    def show
      sha1 = params[:sha1].to_s
      return lookup_error("invalid_sha1", :bad_request) unless /\A[0-9a-fA-F]{40}\z/.match?(sha1)

      release = Release.includes(:game).find_by(sha1: sha1.downcase)
      return lookup_error("release_not_found", :not_found) unless release

      payload = {
        release: release.slice(:sha1, :system, :region, :revision),
        game: { id: release.game.public_id, title: release.game.title }
      }
      expires_in 300, public: true
      render json: payload if stale?(etag: payload, public: true)
    end

    private
      def lookup_error(error, status)
        response.headers["Cache-Control"] = "no-store"
        render json: { error: error }, status: status
      end
  end
end
