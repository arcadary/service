module V1
  class ReleasesController < ApiController
    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :release_not_found

    before_action :set_release
    before_action -> { answer_not_modified(record: @release, version: ReleaseDecorator::VERSION) }

    def show
      render json: ReleaseDecorator.decorate(@release)
    end

    private
      def set_release
        @release = ReleaseService.find_by(sha1: params[:sha1].to_s)
      end

      def invalid_sha1
        render_error("invalid_sha1", status: :bad_request)
      end

      def release_not_found
        render_error("release_not_found", status: :not_found)
      end
  end
end
