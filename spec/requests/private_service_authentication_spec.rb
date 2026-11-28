require "rails_helper"

RSpec.describe "Shared private service authentication", type: :request do
  let(:username) { "disposable-admin" }
  let(:password) { "disposable:password" }
  let(:authorization) { ActionController::HttpAuthentication::Basic.encode_credentials(username, password) }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return(username)
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return(password)
    stub_const("PrivateAuthenticationProbe", Class.new do
      def self.call; end
    end)
    stub_const("PrivateAuthenticationHtmlController", Class.new(ApplicationController) do
      before_action -> { PrivateAuthenticationProbe.call }

      def show
        render plain: "private HTML"
      end
    end)
    stub_const("PrivateAuthenticationApiController", Class.new(ApiController) do
      before_action -> { PrivateAuthenticationProbe.call }

      def show
        render json: { private: true }
      end

      def failure
        raise ActionController::BadRequest, "#{request.authorization} #{request.raw_post}"
      end
    end)
    @original_paths = Rails.application.config.x.private_service_paths
    Rails.application.config.x.private_service_paths = [ %r{\A/authentication-probe(?:/|\z)} ]
    Rails.application.routes.draw do
      get "authentication-probe/html", to: "private_authentication_html#show"
      post "authentication-probe/api.json", to: "private_authentication_api#show"
      post "authentication-probe/failure.json", to: "private_authentication_api#failure"
    end
  end

  after do
    Rails.application.config.x.private_service_paths = @original_paths
    Rails.application.reload_routes!
  end

  def private_request(authorization: nil, path: "/authentication-probe/api.json")
    post path, params: "sensitive request body", headers: {
      "Authorization" => authorization, "CONTENT_TYPE" => "text/plain", "REMOTE_ADDR" => "198.51.100.18"
    }
  end

  def expect_private_response(status:, error: nil)
    expect(response).to have_http_status(status)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.headers["Set-Cookie"]).to be_nil
    expect(response.parsed_body).to eq("error" => error) if error
  end

  [ "VALIDATION_REVIEWER_USERNAME", "VALIDATION_REVIEWER_PASSWORD" ].each do |name|
    [ nil, " \t" ].each do |value|
      it "disables protected work when #{name} is #{value.inspect}" do
        allow(ENV).to receive(:[]).with(name).and_return(value)
        expect(PrivateAuthenticationProbe).not_to receive(:call)
        private_request(authorization: "Basic malformed")
        expect_private_response(status: :service_unavailable, error: "authentication_unavailable")
      end
    end
  end

  {
    "missing credentials" => nil,
    "malformed Basic" => "Basic invalid-base64!",
    "missing password separator" => "Basic #{Base64.strict_encode64('disposable-admin')}",
    "capture bearer token" => "Bearer disposable-token",
    "wrong username" => ActionController::HttpAuthentication::Basic.encode_credentials("other-admin", "disposable:password"),
    "wrong password" => ActionController::HttpAuthentication::Basic.encode_credentials("disposable-admin", "wrong")
  }.each do |description, header|
    it "challenges #{description} before protected callbacks or body parsing" do
      expect(PrivateAuthenticationProbe).not_to receive(:call)
      post "/authentication-probe/api.json", params: "broken JSON", headers: {
        "Authorization" => header, "CONTENT_TYPE" => "application/json"
      }
      expect_private_response(status: :unauthorized, error: "unauthorized")
      expect(response.headers["WWW-Authenticate"]).to eq('Basic realm="Arcadary", charset="UTF-8"')
    end
  end

  it "permits both HTML and API controllers with the configured pair" do
    expect(PrivateAuthenticationProbe).to receive(:call).twice
    get "/authentication-probe/html", headers: { "Authorization" => authorization }
    expect_private_response(status: :ok)
    expect(response.body).to eq("private HTML")
    private_request(authorization: authorization)
    expect_private_response(status: :ok)
    expect(response.parsed_body).to eq("private" => true)
  end

  it "authenticates each request and reads a replacement pair without cached access" do
    expect(PrivateAuthenticationProbe).to receive(:call).twice
    private_request(authorization: authorization)
    expect_private_response(status: :ok)
    private_request
    expect_private_response(status: :unauthorized)
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("replacement-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("replacement-password")
    private_request(authorization: authorization)
    expect_private_response(status: :unauthorized)
    private_request(authorization: ActionController::HttpAuthentication::Basic.encode_credentials("replacement-admin", "replacement-password"))
    expect_private_response(status: :ok)
  end

  it "silences protected successes and failures before logging and hides action exception details" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      private_request(authorization: authorization)
      expect_private_response(status: :ok)
      private_request(authorization: "Basic invalid-base64!")
      expect_private_response(status: :unauthorized)
      private_request(authorization: authorization, path: "/authentication-probe/failure.json")
      expect_private_response(status: :bad_request)
      expect(response.body).not_to include(username, password, authorization, "sensitive request body", "BadRequest")
      allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return(nil)
      private_request(authorization: authorization)
      expect_private_response(status: :service_unavailable)
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end

  it "also protects repeated-slash routes before logging or controller work" do
    expect(PrivateAuthenticationProbe).not_to receive(:call)
    private_request(path: "/authentication-probe//api.json")
    expect_private_response(status: :unauthorized)
  end
end
