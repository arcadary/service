require "swagger_helper"

RSpec.describe "Media", type: :request do
  let!(:release) { create(:release) }
  let!(:shared) { create(:release_medium, media_file: release.media_files.sole) }

  path "/v1/media/{sha1}.json" do
    get "Every release containing an exact file" do
      produces "application/json"
      description "Lists releases in stable public-ID order, each in the release response shape with release.sha1 equal to the asked file. A checksum identifies membership only: the service never infers a set from one checksum or from file names. Successes are public for 300 seconds with ETag and Last-Modified validators; corrections refresh both, while cached responses may remain until their existing TTL expires. Last-Modified is the latest containing release timestamp. Current conditional requests return 304. Errors are never stored."
      parameter name: :sha1, in: :path, required: true,
        schema: { type: :string, pattern: "^[0-9a-fA-F]{40}$" }

      response "200", "containing releases" do
        schema type: :object, required: [ "releases" ], additionalProperties: false,
          properties: { releases: { type: :array, minItems: 1, items: { "$ref" => "#/components/schemas/Release" } } }
        header "Cache-Control", schema: { type: :string, enum: [ "max-age=300, public" ] }
        header "ETag", schema: { type: :string }
        header "Last-Modified", schema: { type: :string }
        let(:sha1) { release.sha1.upcase }
        run_test! do
          releases = response.parsed_body.fetch("releases")
          expect(releases.map { |body| body.dig("release", "id") }).to eq([ release.public_id, shared.release.public_id ].sort)
          expect(releases.map { |body| body.dig("release", "sha1") }.uniq).to eq([ release.sha1 ])
          expect(releases.map { |body| body.fetch("media").size }.sort).to eq([ 1, 2 ])
          expect(response.headers["Set-Cookie"]).to be_nil
        end

        context "with edition-specific profiles" do
          before do
            release.update!(system: "snes", controller_profile: build(:controller_profile))
            shared.release.update!(system: "snes", controller_profile: build(:controller_profile, prompts: []))
          end
          run_test! do
            profiles = response.parsed_body.fetch("releases").to_h { |item| [ item.dig("release", "id"), item.dig("release", "controller_profile") ] }
            expect(profiles.fetch(release.public_id).fetch("prompts")).to eq([ { "letter" => "A", "position" => "right" } ])
            expect(profiles.fetch(shared.release.public_id).fetch("prompts")).to eq([])
          end
        end
      end

      response "400", "malformed SHA-1" do
        schema type: :object, required: [ "error" ], additionalProperties: false,
          properties: { error: { type: :string, enum: [ "invalid_sha1" ] } }
        header "Cache-Control", schema: { type: :string, enum: [ "no-store" ] }
        let(:sha1) { "bad" }
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

  it "revalidates the collection when a member changes or disappears" do
    path = "/v1/media/#{release.sha1}.json"
    get path, headers: { "User-Agent" => "Arcadary/1.0" }
    etag = response.headers.fetch("ETag")
    get path, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    shared.release.game.update!(title: "Renamed")
    get path, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("releases").map { |body| body.dig("game", "title") }).to include("Renamed")
    etag = response.headers.fetch("ETag")
    shared.destroy!
    get path, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("releases").size).to eq(1)
  end
end
