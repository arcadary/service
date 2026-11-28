module V1
  class PlaythroughStagesController < ApiController
    rescue_from PlaythroughStage::InvalidDeclaration, with: -> { render_error("invalid_declaration", status: :bad_request) }
    rescue_from PlaythroughStage::TooLarge, with: -> { render_error("stage_too_large", status: :content_too_large) }
    rescue_from PlaythroughStage::TargetMismatch, with: -> { render_error("target_mismatch", status: :conflict) }
    rescue_from PlaythroughStage::Conflict, with: -> { render_error("stage_conflict", status: :conflict) }
    rescue_from PlaythroughStage::NotFound, Release::ReleaseNotFound, with: -> { render_error("not_found", status: :not_found) }
    rescue_from PlaythroughStage::InterruptedTransfer, with: -> { render_error("interrupted_transfer", status: :bad_request) }
    rescue_from PlaythroughStage::StorageUnavailable, with: -> { render_error("storage_unavailable", status: :service_unavailable) }

    before_action :set_stage, only: :show
    before_action :receive_object, only: :update

    def show
      render json: PlaythroughStageDecorator.decorate(@stage)
    end

    def update
      render json: PlaythroughStageObjectDecorator.decorate(@object)
    end

    private
      def set_stage
        @stage = PlaythroughStagingService.find_by(staging_id: request.path_parameters[:staging_id].to_s)
      end

      def receive_object
        @object = PlaythroughTransferService.receive(staging_id: request.path_parameters[:staging_id].to_s,
          object_id: request.path_parameters[:stage_object_id].to_s, io: request.body, content_type: request.content_type)
      end
  end
end
