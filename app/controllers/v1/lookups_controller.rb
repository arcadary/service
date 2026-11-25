module V1
  class LookupsController < ApiController
    rescue_from Release::InvalidSha1, with: :invalid_sha1

    before_action :lookup_release

    def show
      return redirect_permanently_to(v1_release_path(sha1: sha1)) if @release

      render_error("not_found", status: :not_found)
    end

    private
      def lookup_release
        @release = ReleaseService.exists?(sha1: sha1)
      end

      def sha1
        params[:sha1].to_s.downcase
      end

      def invalid_sha1
        render_error("invalid_sha1", status: :bad_request)
      end
  end
end
