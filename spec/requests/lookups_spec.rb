require "swagger_helper"

RSpec.describe "Lookup", type: :request do
  let(:game) { create(:game, public_id: "lookup-game") }
  let!(:release) { create(:release, game: game, sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "c64") }

  path "/v1/lookup/{sha1}.json" do
    get "Find what a game file is, by its SHA-1" do
      produces "application/json"
      description "Anonymous lookup. A known checksum answers 301 to its resource (today always a release), cached publicly for a day; follow the Location header. Unknown and malformed checksums are never stored."
      parameter name: :sha1, in: :path, required: true,
        schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$" }

      response "301", "known checksum" do
        header "Location", schema: { type: :string }
        header "Cache-Control", schema: { type: :string, enum: [ "max-age=86400, public" ] }
        let(:sha1) { release.sha1.upcase }
        run_test! { expect(response.location).to end_with("/v1/releases/#{release.sha1}.json") }
      end

      response "400", "malformed SHA-1" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_sha1" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "not-a-checksum" }
        run_test!
      end

      response "404", "unknown SHA-1" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "not_found" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "0" * 40 }
        run_test!
      end
    end
  end

  it "leads to the release and its game" do
    get "/v1/lookup/#{release.sha1}.json"
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("game", "id")).to eq("lookup-game")
  end
end
