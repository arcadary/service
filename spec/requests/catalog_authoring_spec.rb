require "rails_helper"

RSpec.describe "Authored catalog output", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
  end

  def correct(operation:, record:, fields:)
    game = record.is_a?(Game) ? record : record.game
    revisions = [ game, *game.releases ].to_h do |affected|
      type = affected.is_a?(Game) ? "game" : "release"
      [ "#{type}:#{affected.public_id}", affected.reload.authoring_revision ]
    end
    CatalogAuthoringService.call(operation: operation, attributes: fields.merge(id: record.public_id),
      expected_revisions: revisions,
      reason: "Synthetic public correction", idempotency_key: SecureRandom.uuid)
  end

  def fetch(path:, etag: nil)
    headers = { "User-Agent" => "Arcadary/1.0" }
    headers["If-None-Match"] = etag if etag
    get path, headers: headers
  end

  it "refreshes every renamed game's release and shared-media validators without exposing authoring state" do
    game, first, sibling, shared = travel_to(1.minute.ago) do
      game = create(:game)
      first = create(:release, game: game)
      sibling = create(:release, game: game)
      shared = create(:release_medium, release: create(:release, game: game), media_file: first.media_files.sole)
      [ game, first, sibling, shared ]
    end
    paths = [ "/v1/releases/#{sibling.sha1}.json", "/v1/releases/#{shared.release.sha1}.json", "/v1/media/#{first.sha1}.json" ]
    validators = paths.to_h do |path|
      fetch(path: path)
      expect(response).to have_http_status(:ok)
      [ path, response.headers.slice("ETag", "Last-Modified") ]
    end
    startup_revisions = [ first, sibling, shared.release ].map { |release| ReleaseStartupService.revision(release: release) }
    correct(operation: :correct_game, record: game, fields: { title: "Authored title", title_aliases: [ "Internal alias" ] })

    paths.each do |path|
      fetch(path: path, etag: validators.fetch(path).fetch("ETag"))
      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Last-Modified")).not_to eq(validators.fetch(path).fetch("Last-Modified"))
      bodies = response.parsed_body.fetch("releases", [ response.parsed_body ])
      bodies.each do |body|
        expect(body.keys).to match_array(%w[release game media startup])
        expect(body.fetch("game").keys).to match_array(%w[id title screenshot])
        expect(body.fetch("release").keys).to match_array(%w[id sha1 system region revision screenshots])
      end
      expect(response.body).to include("Authored title")
      expect(response.body).not_to include("Internal alias", "source_title", "authoring_revision", "authored_fields", "audit_id")
      new_etag = response.headers.fetch("ETag")
      fetch(path: path, etag: new_etag)
      expect(response).to have_http_status(:not_modified)
      expect(response.headers["Set-Cookie"]).to be_nil
    end
    expect([ first, sibling, shared.release ].map { |release| ReleaseStartupService.revision(release: release.reload) }).to eq(startup_revisions)
    fetch(path: "/v1/lookup/#{first.sha1}.json")
    expect(response).to redirect_to("/v1/media/#{first.sha1}.json")
    expect(response.headers["Cache-Control"]).to eq("max-age=86400, public")
    fetch(path: "/v1/lookup/#{sibling.sha1}.json")
    expect(response).to redirect_to("/v1/releases/#{sibling.sha1}.json")
  end

  it "refreshes release metadata and startup through launcher conditional requests" do
    release = travel_to(1.minute.ago) { create(:release, system: "c64") }
    second = travel_to(1.minute.ago) { create(:release_medium, release: release) }
    paths = [ "/v1/releases/#{release.sha1}.json", "/v1/media/#{second.media_file.sha1}.json" ]
    etags = paths.to_h do |path|
      fetch(path: path)
      [ path, response.headers.fetch("ETag") ]
    end
    original_startup = ReleaseStartupService.revision(release: release.reload)
    correct(operation: :correct_release, record: release, fields: { region: "Europe", revision: "Rev B", startup: { schema: 1, boot: "disk-2", drives: { "8" => "disk-2", "9" => "main" } } })
    expect(ReleaseStartupService.revision(release: release.reload)).not_to eq(original_startup)
    paths.each do |path|
      fetch(path: path, etag: etags.fetch(path))
      expect(response).to have_http_status(:ok)
      body = response.parsed_body.fetch("releases", [ response.parsed_body ]).sole
      expect(body.fetch("release")).to include("region" => "Europe", "revision" => "Rev B")
      expect(body.fetch("startup")).to include("boot" => "disk-2")
      fetch(path: path, etag: response.headers.fetch("ETag"))
      expect(response).to have_http_status(:not_modified)
    end
  end
end
