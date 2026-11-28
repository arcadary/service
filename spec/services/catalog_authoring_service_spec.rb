require "rails_helper"

RSpec.describe CatalogAuthoringService do
  before { allow(ENV).to receive(:[]).and_call_original }
  before { allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner") }

  let(:game) { create(:game, source_title: "Original game") }
  let(:release) { create(:release, game: game, system: "c64", source_title: "Original (World)", source_system: "c64", region: "World", source_region: "World", revision: "Rev A", source_revision: "Rev A") }

  def author(operation:, attributes:, expected_revisions: {}, key: SecureRandom.uuid, reason: "Synthetic catalog correction")
    described_class.call(operation: operation, attributes: attributes, expected_revisions: expected_revisions, reason: reason, idempotency_key: key)
  end

  def revisions_for(record:)
    game = record.is_a?(Game) ? record : record.game
    [ game, *game.releases ].to_h do |affected|
      type = affected.is_a?(Game) ? "game" : "release"
      [ "#{type}:#{affected.public_id}", affected.reload.authoring_revision ]
    end
  end

  it "creates authored games and checksum-only media with committed revisions" do
    game_result = author(operation: :create_game, attributes: { id: "synthetic", title: "Synthetic", title_aliases: [ "Alternate" ] })
    expect(game_result.fetch("records").sole).to include("type" => "game", "id" => "synthetic", "authoring_revision" => 1, "authored_fields" => %w[title title_aliases], "source" => { "source_title" => nil })
    media_result = author(operation: :create_media, attributes: { sha1: "a" * 40, size: 174848, format: "d64" })
    expect(media_result.fetch("records").sole).to include("id" => "a" * 40, "authoring_revision" => 1)
    expect(CatalogMutation.count).to eq(2)
  end

  it "creates an ordered release and new media under the current game revision" do
    result = author(operation: :create_release, attributes: { game_id: game.public_id, system: "c64", media: [
      { key: "side-a", position: 1, role: "game", sha1: "a" * 40, size: 174848, format: "d64", crc32: "12345678", md5: "b" * 32 },
      { key: "side-b", position: 2, role: "game", sha1: "c" * 40, label: "Side B" }
    ] }, expected_revisions: { "game:#{game.public_id}" => 0 })
    expect(result.fetch("records").map { |record| record.fetch("type") }).to eq(%w[release media media game])
    expect(result.fetch("records").map { |record| record.fetch("authoring_revision") }).to eq([ 1, 1, 1, 1 ])
    created = Release.last
    expect(ReleaseStartupService.for_release(release: created)).to include("boot" => "side-a", "drives" => { "8" => "side-a" })
    expect(created.media_files.first).to have_attributes(size: 174848, format: "d64", crc32: "12345678", md5: "b" * 32)
    expect(CatalogMutation.last.record_changes.last.fetch("before")).to include("authoring_revision" => 0)
  end

  it "rejects release creation without the current parent revision and rejects existing checksums" do
    attributes = { game_id: game.public_id, system: "gb", media: [ { key: "main", position: 1, role: "game", sha1: "a" * 40 } ] }
    expect { author(operation: :create_release, attributes: attributes) }.to raise_error(described_class::Conflict)
    create(:media_file, sha1: "a" * 40)
    expect { author(operation: :create_release, attributes: attributes, expected_revisions: { "game:#{game.public_id}" => 0 }) }.to raise_error(described_class::Conflict, /existing media/)
    expect(game.reload.authoring_revision).to eq(0)
    expect(game.releases.count).to eq(0)
    expect(CatalogMutation.count).to eq(0)
  end

  it "corrects effective metadata and retains source values and identities" do
    original_id = release.public_id
    original_sha1 = release.sha1
    author(operation: :correct_release, attributes: { id: original_id, system: "gb", region: "Europe", revision: "Rev B", startup: { schema: 1, boot: "main", drives: {} } }, expected_revisions: revisions_for(record: release))
    state = CatalogAuthoringReadService.release(id: original_id)
    expect(state).to include("authoring_revision" => 1, "authored_fields" => %w[region revision startup system], "source" => { "source_title" => "Original (World)", "source_system" => "c64", "source_region" => "World", "source_revision" => "Rev A" })
    expect(state.fetch("canonical")).to include("system" => "gb", "region" => "Europe", "revision" => "Rev B")
    expect(release.reload.sha1).to eq(original_sha1)
  end

  it "validates system and startup together against existing keys without partial writes" do
    release.update!(startup: { schema: 1, boot: "main", drives: { "8" => "main" } })
    expect { author(operation: :correct_release, attributes: { id: release.public_id, system: "gb" }, expected_revisions: revisions_for(record: release)) }.to raise_error(ActiveRecord::RecordInvalid, /unknown drive slot/)
    expect { author(operation: :correct_release, attributes: { id: release.public_id, startup: { schema: 1, boot: "missing", drives: { "8" => "missing" } } }, expected_revisions: revisions_for(record: release)) }.to raise_error(ActiveRecord::RecordInvalid, /unknown medium key/)
    expect(release.reload.system).to eq("c64")
    expect(release.authoring_revision).to eq(0)
    expect(CatalogMutation.count).to eq(0)
  end

  it "keeps searchable aliases separate from importer identity keys" do
    create(:game_identity, game: game)
    author(operation: :correct_game, attributes: { id: game.public_id, title: "Corrected", title_aliases: [ "Other spelling" ] }, expected_revisions: { "game:#{game.public_id}" => 0 })
    expect(CatalogAuthoringReadService.search(query: "SPELLING").sole).to include("id" => game.public_id, "source" => { "source_title" => "Original game" })
    expect(CatalogAuthoringReadService.search(query: "Corrected").sole.fetch("canonical")).to eq("title" => "Corrected", "title_aliases" => [ "Other spelling" ])
    expect(game.game_identities.count).to eq(1)
  end

  it "replays a saved result after revisions advance and rejects a different payload or operation" do
    attributes = { id: game.public_id, title: "Corrected" }
    revisions = { "game:#{game.public_id}" => 0 }
    result = author(operation: :correct_game, attributes: attributes, expected_revisions: revisions, key: "retry")
    replay = author(operation: :correct_game, attributes: attributes.to_a.reverse.to_h, expected_revisions: revisions, key: "retry")
    expect(replay).to eq(result)
    expect(game.reload.authoring_revision).to eq(1)
    expect(CatalogMutation.count).to eq(1)
    expect { author(operation: :correct_game, attributes: attributes.merge(title: "Different"), expected_revisions: revisions, key: "retry") }.to raise_error(described_class::Conflict, /different request/)
    expect { author(operation: :create_game, attributes: attributes, expected_revisions: revisions, key: "retry") }.to raise_error(described_class::Conflict, /different request/)
  end

  it "replays release creation without creating duplicate media or advancing its parent again" do
    attributes = { game_id: game.public_id, system: "gb", media: [ { sha1: "a" * 40, key: "main", position: 1, role: "game" } ] }
    revisions = { "game:#{game.public_id}" => 0 }
    result = author(operation: :create_release, attributes: attributes, expected_revisions: revisions, key: "new-release")
    expect(author(operation: :create_release, attributes: attributes, expected_revisions: revisions, key: "new-release")).to eq(result)
    expect([ game.releases.count, MediaFile.where(sha1: "a" * 40).count, CatalogMutation.count, game.reload.authoring_revision ]).to eq([ 1, 1, 1, 1 ])
    expect { author(operation: :create_release, attributes: attributes, expected_revisions: revisions) }.to raise_error(described_class::Conflict, /stale/)
  end

  it "rejects stale corrections and fields outside the allow-lists without an audit" do
    author(operation: :correct_game, attributes: { id: game.public_id, title: "Current" }, expected_revisions: { "game:#{game.public_id}" => 0 })
    expect { author(operation: :correct_game, attributes: { id: game.public_id, title: "Stale" }, expected_revisions: { "game:#{game.public_id}" => 0 }) }.to raise_error(described_class::Conflict)
    expect { author(operation: :correct_release, attributes: { id: release.public_id, media: [] }, expected_revisions: { "release:#{release.public_id}" => 0 }) }.to raise_error(described_class::InvalidInput)
    expect { author(operation: :create_game, attributes: { id: "bad", title: "Bad", source_title: "Untrusted" }) }.to raise_error(described_class::InvalidInput)
    expect(game.reload.title).to eq("Current")
    expect(CatalogMutation.count).to eq(1)
  end

  it "requires current revisions for every affected release and advances the complete game scope" do
    release
    sibling = create(:release, game: game)
    states = CatalogAuthoringReadService.scope(game_id: game.public_id)
    expect(states.map { |state| state.fetch("id") }).to match_array([ game.public_id, release.public_id, sibling.public_id ])
    revisions = revisions_for(record: game)
    expect { author(operation: :correct_game, attributes: { id: game.public_id, title: "Corrected" }, expected_revisions: revisions.except("release:#{sibling.public_id}")) }.to raise_error(described_class::Conflict)
    result = author(operation: :correct_game, attributes: { id: game.public_id, title: "Corrected" }, expected_revisions: revisions)
    expect(result.fetch("records").map { |state| state.fetch("id") }).to match_array(states.map { |state| state.fetch("id") })
    expect(result.fetch("records").map { |state| state.fetch("authoring_revision") }).to eq([ 1, 1, 1 ])
    expect(CatalogMutation.count).to eq(1)
  end

  it "rolls invalid release creation back without creating files or advancing the game" do
    attributes = { game_id: game.public_id, system: "c64", startup: { schema: 1, boot: "missing", drives: { "8" => "missing" } }, media: [ { key: "main", position: 1, role: "game", sha1: "a" * 40 } ] }
    expect { author(operation: :create_release, attributes: attributes, expected_revisions: revisions_for(record: game)) }.to raise_error(ActiveRecord::RecordInvalid)
    expect([ game.releases.count, MediaFile.where(sha1: "a" * 40).count, CatalogMutation.count, game.reload.authoring_revision ]).to eq([ 0, 0, 0, 0 ])
  end

  it "fails closed for blank admin name, reason or retry key" do
    attributes = { id: game.public_id, title: "Corrected" }
    expect { author(operation: :correct_game, attributes: attributes, reason: " ") }.to raise_error(described_class::InvalidInput)
    expect { author(operation: :correct_game, attributes: attributes, key: " ") }.to raise_error(described_class::InvalidInput)
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return(" ")
    expect { author(operation: :correct_game, attributes: attributes) }.to raise_error(described_class::MissingAdminName)
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return(nil)
    expect { author(operation: :correct_game, attributes: attributes) }.to raise_error(described_class::MissingAdminName)
    expect(game.reload.title).to eq("A game")
    expect(CatalogMutation.count).to eq(0)
  end

  it "rolls records and history back together on persistence failure" do
    game
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "synthetic persistence failure")
    expect { author(operation: :correct_game, attributes: { id: game.public_id, title: "Corrected" }, expected_revisions: { "game:#{game.public_id}" => 0 }) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(game.reload).to have_attributes(title: "A game", authoring_revision: 0)
    expect(CatalogMutation.count).to eq(0)
  end

  it "compensates as a new correction and retains bounded, paginated original history" do
    first = author(operation: :correct_game, attributes: { id: game.public_id, title: "Temporary" }, expected_revisions: { "game:#{game.public_id}" => 0 }, reason: "Correct synthetic title")
    author(operation: :correct_game, attributes: { id: game.public_id, title: "A game" }, expected_revisions: { "game:#{game.public_id}" => 1 }, reason: "Compensate earlier title correction")
    entries = CatalogAuthoringReadService.history(limit: 1)
    expect(entries.sole).to include("admin_name" => "Catalog Owner", "reason" => "Compensate earlier title correction")
    expect(entries.sole.fetch("created_at")).to be_present
    expect(entries.sole.fetch("record_changes").sole.fetch("before").dig("canonical", "title")).to eq("Temporary")
    older = CatalogAuthoringReadService.history(limit: 1, before_id: entries.sole.fetch("id"))
    expect(older.sole.fetch("id")).to eq(first.fetch("audit_id"))
    expect(older.sole.fetch("record_changes").sole.fetch("after").dig("canonical", "title")).to eq("Temporary")
    expect { CatalogAuthoringReadService.history(limit: 101) }.to raise_error(ArgumentError)
    expect(CatalogMutation.count).to eq(2)
    expect(game.reload.authoring_revision).to eq(2)
  end
end
