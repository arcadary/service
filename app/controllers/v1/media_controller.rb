module V1
  class MediaController < ApiController
    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :not_found

    before_action :set_releases
    before_action :answer_current_collection

    def show
      render json: MediaDecorator.decorate(@releases, sha1: @sha1)
    end

    private
      def set_releases
        @sha1 = params[:sha1].to_s.downcase
        @releases = ReleaseService.containing(sha1: @sha1)
      end

      def answer_current_collection
        expires_in 5.minutes, public: true
        fresh_when(etag: [ MediaDecorator.version, @sha1, *@releases ], last_modified: @releases.map(&:updated_at).max, public: true)
      end

      def invalid_sha1
        render_error("invalid_sha1", status: :bad_request)
      end

      def not_found
        render_error("not_found", status: :not_found)
      end
  end
end
