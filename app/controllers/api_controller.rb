class ApiController < ActionController::API
  include ConditionalGet

  private
    def redirect_permanently_to(path, max_age: 1.day)
      expires_in max_age, public: true
      redirect_to path, status: :moved_permanently
    end

    def render_error(code, status:)
      response.headers["Cache-Control"] = "no-store"
      render json: { error: code }, status: status
    end
end
