require "swagger_helper"

RSpec.describe "Release", type: :request do
  let(:game) { create(:game, public_id: "lookup-game") }
  let!(:release) { create(:release, game: game, sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "c64") }
  let(:url) { "/v1/releases/#{release.sha1}.json" }
  let(:expected_payload) do
    {
      "release" => { "sha1" => release.sha1, "system" => "c64", "region" => nil, "revision" => nil },
      "game" => { "id" => "lookup-game", "title" => "A game" }
    }
  end

  path "/v1/releases/{sha1}.json" do
    get "A release and its game, by the SHA-1 of its game file" do
      produces "application/json"
      description "The target of a lookup redirect. Hex is case-insensitive. Successes are public for 300 seconds with an ETag; errors are never stored."
      parameter name: :sha1, in: :path, required: true,
        schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$", minLength: 40, maxLength: 40 }

      response "200", "release and game" do
        schema type: :object, required: %w[release game], additionalProperties: false,
          properties: {
            release: {
              type: :object, required: %w[sha1 system region revision], additionalProperties: false,
              properties: {
                sha1: { type: :string, pattern: "^[0-9a-f]{40}$" },
                system: { type: :string, enum: %w[nes snes gb gbc megadrive pcengine atari2600 c64] },
                region: { type: :string, nullable: true }, revision: { type: :string, nullable: true }
              }
            },
            game: {
              type: :object, required: %w[id title], additionalProperties: false,
              properties: { id: { type: :string }, title: { type: :string } }
            }
          }
        header "Cache-Control", schema: { type: :string, enum: [ "max-age=300, public" ] }
        header "ETag", schema: { type: :string }
        let(:sha1) { release.sha1 }
        run_test! { expect(response.parsed_body).to eq(expected_payload) }

        context "upper-case hex" do
          let(:sha1) { release.sha1.upcase }
          run_test! { expect(response.parsed_body).to eq(expected_payload) }
        end
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
          properties: { error: { type: :string, enum: [ "release_not_found" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "0" * 40 }
        run_test!
      end
    end
  end

  it "answers 304 when the client's copy is current" do
    get url
    expect(response.headers["Cache-Control"]).to eq("max-age=300, public")
    get url, headers: { "If-None-Match" => response.headers.fetch("ETag") }
    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
    expect(response.headers["Set-Cookie"]).to be_nil
  end

  it "answers 200 again once the game is renamed" do
    get url
    etag = response.headers.fetch("ETag")
    game.update!(title: "Renamed")
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("game", "title")).to eq("Renamed")
  end

  it "answers 200 again once the game's JSON shape changes" do
    get url
    etag = response.headers.fetch("ETag")
    stub_const("GameDecorator::VERSION", GameDecorator::VERSION + 1)
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
  end

  it "finds a release added after an unknown lookup" do
    path = "/v1/releases/#{'0' * 40}.json"
    get path
    expect(response).to have_http_status(:not_found)
    create(:release, game: game, sha1: "0" * 40, system: "gb")
    get path
    expect(response).to have_http_status(:ok)
  end

  it "logs nothing about a lookup" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      [ release.sha1, "0" * 40, "not-a-checksum" ].each do |sha1|
        get "/v1/lookup/#{sha1}.json", headers: { "REMOTE_ADDR" => "198.51.100.18" }
        get "/v1/releases/#{sha1}.json", headers: { "REMOTE_ADDR" => "198.51.100.18" }
      end
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
