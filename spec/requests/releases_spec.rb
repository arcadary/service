require "swagger_helper"

RSpec.describe "Release", type: :request do
  let(:game) { create(:game, public_id: "lookup-game") }
  let!(:release) { create(:release, game: game, sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "c64") }
  let(:url) { "/v1/releases/#{release.sha1}.json" }
  let(:expected_payload) do
    {
      "release" => { "id" => release.public_id, "sha1" => release.sha1, "system" => "c64", "region" => nil, "revision" => nil, "screenshots" => [], "compatibility" => { "steam_machine" => { "status" => "unknown" }, "steam_deck" => { "status" => "unknown" } }, "videos" => [] },
      "game" => { "id" => "lookup-game", "title" => "A game", "screenshot" => nil },
      "media" => [ { "key" => "main", "position" => 1, "label" => nil, "role" => "game", "sha1" => release.sha1, "size" => nil, "format" => nil } ],
      "startup" => { "schema" => 1, "boot" => "main", "drives" => { "8" => "main" }, "revision" => "20ac504497948774502ee889d50c8b20f4dcb493ee0a66f064e818b91cb8c9ff" }
    }
  end

  path "/v1/releases/{sha1}.json" do
    get "A release and its game, by the SHA-1 of its game file" do
      produces "application/json"
      description "The target of an unambiguous lookup redirect. Hex is case-insensitive; release.sha1 is the asked file and release.id identifies the whole release. Media are in position order. Startup applies defaults and includes a SHA-256 revision over effective startup and ordered checksums. C64 slots are 8 and 9; other systems have no drives. release.compatibility gives works, attention (with a reason), does_not_work or unknown for steam_machine and steam_deck separately: the newest recorded result under the current startup revision, with its core, core version, evidence and the input devices besides the controller it needs (requires_input), or unknown. The service never infers a set from one checksum or from file names. Successes are public for 300 seconds with ETag and Last-Modified validators; corrections refresh both, while cached responses may remain until their existing TTL expires. Current conditional requests return 304. Errors are never stored."
      parameter name: :sha1, in: :path, required: true,
        schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$", minLength: 40, maxLength: 40 }

      response "200", "release and game" do
        schema "$ref" => "#/components/schemas/Release"
        header "Cache-Control", schema: { type: :string, enum: [ "max-age=300, public" ] }
        header "ETag", schema: { type: :string }
        header "Last-Modified", schema: { type: :string }
        let(:sha1) { release.sha1 }
        run_test! { expect(response.parsed_body).to eq(expected_payload) }

        context "upper-case hex" do
          let(:sha1) { release.sha1.upcase }
          run_test! { expect(response.parsed_body).to eq(expected_payload) }
        end

        context "with a Steam Machine result only" do
          before { create(:compatibility_result, release: release, status: "does_not_work", reason: "Hangs after loading.", core: "vice", core_version: "3.9", observed: "Hangs after loading.", limits: "Only the first disk tried.") }
          run_test! do
            expect(response.parsed_body.dig("release", "compatibility")).to eq(
              "steam_machine" => { "status" => "does_not_work", "reason" => "Hangs after loading.", "core" => "vice", "core_version" => "3.9", "startup_revision" => expected_payload.dig("startup", "revision"),
                "tested_at" => "2026-11-20T18:00:00Z", "observed" => "Hangs after loading.", "limits" => "Only the first disk tried.", "requires_input" => [] },
              "steam_deck" => { "status" => "unknown" })
          end
        end

        context "with a playthrough" do
          before do
            create(:video, release: release, public_id: "synthetic-video", media: { "format" => "fmp4", "audio" => true, "duration" => 5400.25,
              "chapters" => [ { "start" => 0.0, "end" => 600.5, "title" => "World 1" } ] })
          end

          run_test! do
            expect(response.parsed_body.dig("release", "videos")).to eq([
              { "kind" => "playthrough", "url" => "https://media.example/videos/synthetic-video/index.m3u8", "duration" => 5400.25,
                "chapters" => [ { "start" => 0.0, "end" => 600.5, "title" => "World 1" } ] }
            ])
          end
        end

        context "with an authored original controller profile" do
          before { release.update!(system: "snes", controller_profile: build(:controller_profile)) }
          run_test! do
            expect(response.parsed_body.dig("release", "controller_profile")).to eq(
              ReleaseControllerProfileDecorator.decorate(release.controller_profile).as_json)
          end
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

      response "409", "file belongs to several releases; use /v1/media/{sha1}.json" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "ambiguous_release" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { release.sha1 }
        before { create(:release_medium, media_file: release.media_files.sole) }
        run_test!
      end
    end
  end

  it "returns the same ordered set and startup for every disk, with the asked checksum" do
    second = create(:release_medium, release: release, label: "Side B")
    save_disk = create(:release_medium, release: release, key: "save", position: 3, role: "save", label: "Save disk")
    release.update!(startup: { "schema" => 1, "boot" => "disk-2", "drives" => { "8" => "disk-2", "9" => "main" } })
    bodies = [ release.sha1, second.media_file.sha1, save_disk.media_file.sha1 ].map do |sha1|
      get "/v1/releases/#{sha1}.json", headers: { "User-Agent" => "Arcadary/1.0" }
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.fetch("release")).to include("id" => release.public_id, "sha1" => sha1)
      body.fetch("release").delete("sha1")
      body
    end
    expect(bodies.uniq.size).to eq(1)
    expect(bodies.first.fetch("media").map { |medium| medium.values_at("key", "position", "label", "role") }).to eq([
      [ "main", 1, nil, "game" ], [ "disk-2", 2, "Side B", "game" ], [ "save", 3, "Save disk", "save" ]
    ])
    expect(bodies.first.fetch("startup")).to include("boot" => "disk-2", "drives" => { "8" => "disk-2", "9" => "main" })
  end

  it "invalidates validators for media, startup and decorator changes, and distinguishes asked disks" do
    medium = create(:release_medium, release: release)
    get url
    etag = response.headers.fetch("ETag")
    medium.update!(label: "Side B")
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    etag = response.headers.fetch("ETag")
    medium.media_file.update!(size: 196608)
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    etag = response.headers.fetch("ETag")
    release.reload.update!(startup: { "schema" => 1, "boot" => "disk-2", "drives" => { "8" => "disk-2" } })
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    etag = response.headers.fetch("ETag")
    get "/v1/releases/#{medium.media_file.sha1}.json", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    stub_const("ReleaseDecorator::VERSION", ReleaseDecorator::VERSION + 1)
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
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
        get "/v1/media/#{sha1}.json", headers: { "REMOTE_ADDR" => "198.51.100.18" }
      end
      expect(output.string).to eq("")
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
  end
end
