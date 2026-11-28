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

  def fetch(path:, etag: nil, modified_since: nil)
    headers = { "User-Agent" => "Arcadary/1.0" }
    headers["If-None-Match"] = etag if etag
    headers["If-Modified-Since"] = modified_since if modified_since
    get path, headers: headers
  end

  def relate(operation:, attributes:)
    proposal = CatalogAuthoringService.preview(operation: operation, attributes: attributes)
    CatalogAuthoringService.call(operation: operation, attributes: attributes, preview: proposal,
      expected_revisions: proposal.fetch("expected_revisions"), reason: "Synthetic public relationship correction", idempotency_key: SecureRandom.uuid)
  end

  def validators_for(paths:)
    paths.to_h do |path|
      fetch(path: path)
      expect(response).to have_http_status(:ok)
      [ path, response.headers.slice("ETag", "Last-Modified") ]
    end
  end

  def expect_refreshed(validators:)
    validators.each do |path, headers|
      fetch(path: path, etag: headers.fetch("ETag"))
      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Last-Modified")).not_to eq(headers.fetch("Last-Modified"))
      expect(response.headers.fetch("Cache-Control")).to eq("max-age=300, public")
      expect(response.headers["Set-Cookie"]).to be_nil
      expect(response.body).not_to include("retired_into_game_id", "importer_keys", "authoring_revision", "authored_fields")
      current_etag = response.headers.fetch("ETag")
      fetch(path: path, etag: current_etag)
      expect(response).to have_http_status(:not_modified)
      fetch(path: path, modified_since: headers.fetch("Last-Modified"))
      expect(response).to have_http_status(:ok)
    end
  end

  it "refreshes both grouping sides and shared resources through reassignment, merge and restore" do
    source, target, moving, sibling, existing = travel_to(1.minute.ago) do
      source = create(:game)
      target = create(:game)
      moving = create(:release, game: source)
      sibling = create(:release, game: source)
      existing = create(:release, game: target)
      create(:release_medium, media_file: moving.media_files.sole)
      [ source, target, moving, sibling, existing ]
    end
    paths = [ "/v1/releases/#{sibling.sha1}.json", "/v1/releases/#{existing.sha1}.json", "/v1/media/#{moving.sha1}.json" ]
    operations = [
      [ :reassign_release, { id: moving.public_id, game_id: target.public_id } ],
      [ :merge_games, { id: source.public_id, into_game_id: target.public_id } ],
      [ :restore_game, { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ moving.public_id, sibling.public_id ] } ]
    ]
    operations.each_with_index do |(operation, attributes), index|
      validators = validators_for(paths: paths)
      travel_to(Time.current + (index + 1).minutes) do
        relate(operation: operation, attributes: attributes)
        expect_refreshed(validators: validators)
      end
    end
    fetch(path: "/v1/media/#{moving.sha1}.json")
    moved = response.parsed_body.fetch("releases").find { |body| body.dig("release", "id") == moving.public_id }
    expect(moved.dig("game", "id")).to eq(source.public_id)
  end

  it "updates lookup, ambiguity and remaining-member validators after existing-checksum attachment and removal" do
    editor, removed, shared, unique = travel_to(1.minute.ago) do
      editor = create(:release, system: "c64")
      removed = create(:release_medium, release: editor)
      shared = create(:release)
      unique = create(:release_medium, release: shared)
      [ editor, removed, shared, unique ]
    end
    paths = [ "/v1/releases/#{editor.sha1}.json", "/v1/releases/#{unique.media_file.sha1}.json", "/v1/media/#{shared.sha1}.json" ]
    media = CatalogAuthoringReadService.release(id: editor.public_id).dig("canonical", "media").first(1)
    validators = validators_for(paths: paths)
    relate(operation: :correct_release, attributes: { id: editor.public_id, media: media + [ { key: "shared", position: 2, role: "game", sha1: shared.sha1 } ] })
    expect_refreshed(validators: validators)
    fetch(path: "/v1/lookup/#{removed.media_file.sha1}.json")
    expect(response).to have_http_status(:not_found)
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    fetch(path: "/v1/releases/#{removed.media_file.sha1}.json")
    expect(response).to have_http_status(:not_found)
    fetch(path: "/v1/lookup/#{shared.sha1}.json")
    expect(response).to redirect_to("/v1/media/#{shared.sha1}.json")
    expect(response.headers.fetch("Cache-Control")).to eq("max-age=86400, public")
    fetch(path: "/v1/releases/#{shared.sha1}.json")
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "ambiguous_release")
    expect(response.headers.fetch("Cache-Control")).to eq("no-store")
    validators = validators_for(paths: paths)
    travel_to(1.minute.from_now) do
      relate(operation: :correct_release, attributes: { id: editor.public_id, media: media })
      expect_refreshed(validators: validators)
      fetch(path: "/v1/lookup/#{shared.sha1}.json")
      expect(response).to redirect_to("/v1/releases/#{shared.sha1}.json")
      expect(response.headers.fetch("Cache-Control")).to eq("max-age=86400, public")
      fetch(path: "/v1/releases/#{shared.sha1}.json")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("release", "id")).to eq(shared.public_id)
    end
  end

  it "refreshes each containing release and shared representation after a checksum metadata correction" do
    first, second = travel_to(1.minute.ago) do
      first = create(:release)
      second = create(:release)
      create(:release_medium, release: second, media_file: first.media_files.sole)
      [ first, second ]
    end
    paths = [ "/v1/releases/#{second.sha1}.json", "/v1/media/#{first.sha1}.json" ]
    validators = validators_for(paths: paths)
    startup = [ first, second ].map { |release| ReleaseStartupService.revision(release: release.reload) }
    relate(operation: :correct_media, attributes: { sha1: first.sha1, size: 174848, format: "d64" })
    expect_refreshed(validators: validators)
    expect([ first, second ].map { |release| ReleaseStartupService.revision(release: release.reload) }).to eq(startup)
    fetch(path: "/v1/media/#{first.sha1}.json")
    response.parsed_body.fetch("releases").each do |body|
      file = body.fetch("media").find { |medium| medium.fetch("sha1") == first.sha1 }
      expect(file).to include("size" => 174848, "format" => "d64")
    end
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
        expect(body.fetch("release").keys).to match_array(%w[id sha1 system region revision screenshots compatibility])
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
