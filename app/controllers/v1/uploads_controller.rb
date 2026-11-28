module V1
  class UploadsController < ApiController
    rescue_from Upload::NotFound, with: -> { render_error("not_found", status: :not_found) }
    rescue_from Upload::Conflict, with: -> { render_error("upload_conflict", status: :conflict) }
    rescue_from Upload::Expired, with: -> { render_error("upload_expired", status: :gone) }
    rescue_from Upload::TooLarge, with: -> { render_error("upload_too_large", status: :content_too_large) }
    rescue_from Upload::Rejected, with: -> { render_error("upload_rejected", status: :unprocessable_content) }
    rescue_from Upload::Full, with: -> { render_error("uploads_full", status: :insufficient_storage) }
    rescue_from Upload::InterruptedTransfer, with: -> { render_error("interrupted_transfer", status: :bad_request) }
    rescue_from Upload::StorageUnavailable, with: -> { render_error("storage_unavailable", status: :service_unavailable) }

    before_action :set_upload, only: :show
    before_action :receive_file, only: :update

    def show
      render json: UploadDecorator.decorate(@upload)
    end

    def update
      render json: UploadFileDecorator.decorate(@file)
    end

    private
      def set_upload
        @upload = UploadService.find_by(upload_id: params[:upload_id].to_s)
      end

      def receive_file
        @file = UploadService.receive(upload_id: params[:upload_id].to_s, name: params[:name].to_s, io: request.body,
          content_type: request.media_type, content_length: request.content_length&.to_i, digest: request.headers["Content-Digest"])
      end
  end
end
