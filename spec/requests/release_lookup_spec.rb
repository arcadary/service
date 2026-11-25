require "swagger_helper"

RSpec.describe "Release lookup", type: :request do
  let(:game) { Game.create!(public_id: "lookup-game", title: "A game") }
  let!(:release) { game.releases.create!(sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "c64") }
  let(:url) { "/v1/releases/sha1/#{release.sha1}.json" }
  let(:expected_payload) do
    {
      "release" => { "sha1" => release.sha1, "system" => "c64", "region" => nil, "revision" => nil },
      "game" => { "id" => "lookup-game", "title" => "A game" }
    }
  end

  path "/v1/releases/sha1/{sha1}.json" do
    get "Identify a game file by SHA-1" do
      produces "application/json"
      description "Anonymous, cookie-free lookup. The .json suffix is required. Hex is case-insensitive. Successes are public for 300 seconds with an ETag; errors are never stored."
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

        context "mixed-case hex" do
          let(:sha1) { "AbCdEf0123456789aBcDeF0123456789ABCDEF01" }
          run_test! { expect(response.parsed_body).to eq(expected_payload) }
        end

        context "upper-case hex" do
          let(:sha1) { release.sha1.upcase }
          run_test! { expect(response.parsed_body).to eq(expected_payload) }
        end
      end

      response "400", "malformed SHA-1" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_sha1" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "a" * 39 }
        run_test!

        context "too long" do
          let(:sha1) { "a" * 41 }
          run_test!
        end

        context "non-hex" do
          let(:sha1) { "g" * 40 }
          run_test!
        end

        context "punctuation in segment" do
          let(:sha1) { "invalid.checksum" }
          run_test!
        end
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

  it "returns public caching and an empty conditional response with the same validator" do
    get url
    expect(response.headers["Cache-Control"]).to eq("max-age=300, public")
    etag = response.headers.fetch("ETag")
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    expect(response.body).to be_empty
    expect(response.headers["Cache-Control"]).to eq("max-age=300, public")
    expect(response.headers["ETag"]).to eq(etag)
    expect(response.headers["Set-Cookie"]).to be_nil
  end

  it "does not tie the JSON validator to the importmap digest" do
    allow(Rails.application.importmap).to receive(:digest).and_return("first-digest")
    get url
    etag = response.headers.fetch("ETag")
    body = response.body
    allow(Rails.application.importmap).to receive(:digest).and_return("changed-digest")
    get url
    expect(response.body).to eq(body)
    expect(response.headers["ETag"]).to eq(etag)
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    expect(response.headers["ETag"]).to eq(etag)
  end

  [ [ :game, :title, "Renamed" ], [ :game, :public_id, "corrected-id" ],
    [ :release, :sha1, "1" * 40 ], [ :release, :system, "nes" ],
    [ :release, :region, "Japan" ], [ :release, :revision, "Rev B" ] ].each do |record, field, value|
    it "invalidates the ETag when #{record}.#{field} changes" do
      get url
      etag = response.headers.fetch("ETag")
      # Public IDs cannot change through ordinary model updates; this also proves
      # the validator covers the returned ID after an exceptional data correction.
      public_send(record).update_columns(field => value)
      get "/v1/releases/sha1/#{release.reload.sha1}.json", headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:ok)
      expect(response.headers["ETag"]).not_to eq(etag)
    end
  end

  %i[region revision].each do |field|
    it "invalidates the ETag when #{field} changes between null and an empty string" do
      get url
      expect(response.parsed_body.fetch("release").fetch(field.to_s)).to be_nil
      etag = response.headers.fetch("ETag")

      [ "", nil ].each do |value|
        release.update!(field => value)
        get url, headers: { "If-None-Match" => etag }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.fetch("release").fetch(field.to_s)).to eq(value)
        expect(response.headers["ETag"]).not_to eq(etag)
        etag = response.headers.fetch("ETag")
      end
    end
  end

  [ [ "0" * 40, 404, "release_not_found" ], [ "not-hex", 400, "invalid_sha1" ] ].each do |sha1, status, error|
    it "never caches or conditionally returns 304 for #{status}" do
      path = "/v1/releases/sha1/#{sha1}.json"
      get path
      expect(response.status).to eq(status)
      expect(response.parsed_body).to eq("error" => error)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["ETag"]).to be_nil
      get path, headers: { "If-None-Match" => "*" }
      expect(response.status).to eq(status)
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.headers["ETag"]).to be_nil
    end
  end

  it "immediately reveals a newly added release after an unknown lookup" do
    path = "/v1/releases/sha1/#{'0' * 40}.json"
    get path
    expect(response).to have_http_status(:not_found)
    game.releases.create!(sha1: "0" * 40, system: "gb")
    get path
    expect(response).to have_http_status(:ok)
  end

  it "returns identical anonymous bytes for success and errors regardless of caller headers" do
    [ url, "/v1/releases/sha1/#{'0' * 40}.json", "/v1/releases/sha1/invalid.json" ].each do |path|
      get path
      status, body, etag = response.status, response.body, response.headers["ETag"]
      [
        { "User-Agent" => "" },
        { "User-Agent" => "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 Chrome/40.0.0.0 Safari/537.36" },
        { "Cookie" => "session=household", "Authorization" => "Bearer caller-secret",
          "Accept" => "text/html", "Accept-Language" => "de", "User-Agent" => "Arcadary/1.0" }
      ].each do |headers|
        get path, headers: headers
        expect(response.status).to eq(status)
        expect(response.body).to eq(body)
        expect(response.media_type).to eq("application/json")
        expect(response.headers["ETag"]).to eq(etag)
        expect(response.headers["Set-Cookie"]).to be_nil
        expect(response.headers["Vary"]).to be_nil
      end
    end
  end

  it "requires the JSON suffix" do
    get "/v1/releases/sha1/#{release.sha1}"
    expect(response).to have_http_status(:not_found)
    get "/v1/releases/sha1/#{release.sha1}.html"
    expect(response).to have_http_status(:not_found)
  end

  it "silences request-start, parameter, controller and SQL logging for all lookup outcomes" do
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    capture.level = Logger::DEBUG
    Rails.logger.broadcast_to(capture)
    begin
      get "/up"
      ActiveRecord::Base.connection.execute("SELECT 12345")
      expect(output.string).to include("Started GET", "SELECT 12345")
      output.truncate(0)
      output.rewind
      [ "/v1/releases/sha1/", "//v1/releases/sha1/", "/v1//releases/sha1/",
        "/v1/releases//sha1/", "/v1/releases/sha1//", "///v1///releases///sha1///" ].each do |prefix|
        [ [ release.sha1, 200 ], [ "0" * 40, 404 ], [ "not-hex", 400 ] ].each do |sha1, status|
          get "#{prefix}#{sha1}.json", headers: {
            "REMOTE_ADDR" => "198.51.100.18", "X-Forwarded-For" => "203.0.113.19",
            "Forwarded" => "for=203.0.113.19", "X-Request-ID" => "household-marker",
            "Cookie" => "household=cookie-marker", "Authorization" => "Bearer caller-secret"
          }
          expect(response.status).to eq(status)
        end
      end
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
