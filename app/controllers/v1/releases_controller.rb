module V1
  class ReleasesController < ApiController
    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :release_not_found
    rescue_from Release::AmbiguousRelease, with: :ambiguous_release

    before_action :set_release
    before_action -> { answer_not_modified(record: @release, version: [ ReleaseDecorator.version, @sha1 ]) }

    def show
      render json: ReleaseDecorator.decorate(@release, sha1: @sha1)
    end

    private
      def set_release
        @sha1 = params[:sha1].to_s.downcase
        @release = ReleaseService.find_by(sha1: @sha1)
      end

      def invalid_sha1
        render_error("invalid_sha1", status: :bad_request)
      end

      def release_not_found
        render_error("release_not_found", status: :not_found)
      end

      def ambiguous_release
        render_error("ambiguous_release", status: :conflict)
      end
  end
end
