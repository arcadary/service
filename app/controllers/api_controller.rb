class ApiController < ActionController::API
  include ConditionalGet

  private
    def render_error(code, status:)
      response.headers["Cache-Control"] = "no-store"
      render json: { error: code }, status: status
    end
end
