module V1
  class LookupsController < ApiController
    rescue_from Release::InvalidSha1, with: :invalid_sha1
    rescue_from Release::ReleaseNotFound, with: :not_found

    before_action :lookup_release

    def show
      redirect_permanently_to(@resource.fetch(:resource) == :release ? release_path(@resource.fetch(:sha1)) : media_path(@resource.fetch(:sha1)))
    end

    private
      def lookup_release
        @resource = ReleaseService.resource_for(sha1: params[:sha1].to_s)
      end

      def invalid_sha1
        render_error("invalid_sha1", status: :bad_request)
      end

      def not_found
        render_error("not_found", status: :not_found)
      end
  end
end
