require "rails_helper"

RSpec.describe "Controller profile lookup and validators", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  it "keeps absent facts absent and shared files ambiguous without disclosing evidence" do
    release = create(:release, system: "snes", controller_profile: build(:controller_profile))
    absent = create(:release, system: "snes", game: release.game)
    create(:release_medium, release: absent, media_file: release.media_files.sole)
    get "/v1/lookup/#{release.sha1}.json", headers: { "User-Agent" => "Arcadary/1.0" }
    expect(response).to have_http_status(:moved_permanently)
    expect(response.location).to end_with("/v1/media/#{release.sha1}.json")
    expect(response.headers["Cache-Control"]).to eq("max-age=86400, public")
    get "/v1/releases/#{release.sha1}.json"
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "ambiguous_release")
    get "/v1/media/#{release.sha1}.json"
    candidates = response.parsed_body.fetch("releases").to_h { |item| [ item.dig("release", "id"), item.fetch("release") ] }
    expect(candidates.fetch(absent.public_id)).not_to have_key("controller_profile")
    expect(candidates.fetch(release.public_id).fetch("controller_profile")).to eq(
      "version" => 1, "layout" => release.controller_profile.fetch("layout").map { |item| item.slice("position", "label") },
      "prompts" => [ { "letter" => "A", "position" => "right" } ])
    expect(response.body).not_to match(/Synthetic|evidence|binding/)
    expect(response.headers["Set-Cookie"]).to be_nil
  end

  it "refreshes release and containing media validators for launcher reads after a profile correction" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Synthetic Owner")
    release = create(:release, system: "snes")
    urls = [ "/v1/releases/#{release.sha1}.json", "/v1/media/#{release.sha1}.json" ]
    validators = urls.map do |url|
      get url, headers: { "User-Agent" => "Arcadary/1.0" }
      response.headers.slice("ETag", "Last-Modified")
    end
    travel 2.seconds do
      CatalogAuthoringService.call(operation: :correct_release, attributes: { id: release.public_id, controller_profile: build(:controller_profile) },
        expected_revisions: { "game:#{release.game.public_id}" => 0, "release:#{release.public_id}" => 0 },
        reason: "Synthetic profile", idempotency_key: "public-profile")
      urls.each_with_index do |url, index|
        { "If-None-Match" => "ETag", "If-Modified-Since" => "Last-Modified" }.each do |request_header, response_header|
          get url, headers: { "User-Agent" => "Arcadary/1.0", request_header => validators[index].fetch(response_header) }
          expect(response).to have_http_status(:ok)
          expect(response.body).to include('"controller_profile"')
          expect(response.headers["Cache-Control"]).to eq("max-age=300, public")
          expect(response.headers["Set-Cookie"]).to be_nil
          current = response.headers.fetch(response_header)
          expect(current).not_to eq(validators[index].fetch(response_header))
          get url, headers: { "User-Agent" => "Arcadary/1.0", request_header => current }
          expect(response).to have_http_status(:not_modified)
        end
      end
    end
  end
end
