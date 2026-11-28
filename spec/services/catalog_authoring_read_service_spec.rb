require "rails_helper"

RSpec.describe CatalogAuthoringReadService do
  it "resolves chained IDs while exposing each retained identity's own metadata and keys" do
    canonical = create(:game, title: "Current", title_aliases: [ "Shared" ])
    retired = create(:game, title: "Original", title_aliases: [ "Shared" ], source_title: "Source", catalog_curated: true, screenshot_licence: "CC0", retired_into_game: canonical)
    oldest = create(:game, title: "Oldest", retired_into_game: retired)
    key = create(:game_identity, game: retired)
    release = create(:release, game: canonical)

    expect(described_class.game(id: oldest.public_id)).to include("id" => canonical.public_id, "requested_id" => oldest.public_id)
    raw = described_class.record(retired)
    expect(raw).to include("id" => retired.public_id, "authoring_revision" => 0,
      "canonical" => { "title" => "Original", "title_aliases" => [ "Shared" ] }, "source" => { "source_title" => "Source" })
    expect(raw.fetch("identity")).to eq("state" => "retired", "retired_into_game_id" => canonical.public_id,
      "canonical_game_id" => canonical.public_id, "screenshot_licence" => "CC0", "catalog_curated" => true, "importer_keys" => [ key.key ])
    expect(described_class.scope(game_id: oldest.public_id)).to eq(described_class.scope(game_id: canonical.public_id))
    expect(described_class.scope(game_id: retired.public_id).map { |state| state.fetch("id") }).to match_array([ canonical.public_id, retired.public_id, oldest.public_id, release.public_id ])
    expect(described_class.search(query: "shared").map { |state| state.fetch("id") }).to eq([ canonical.public_id ])
    expect(described_class.search(query: "OLDEST").sole.fetch("id")).to eq(canonical.public_id)
  end
end
