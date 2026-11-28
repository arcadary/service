require "rails_helper"
require_relative "../support/catalog_helpers"

RSpec.describe "Reference imports after authoring" do
  include CatalogHelpers

  around do |example|
    Dir.mktmpdir("catalog-authoring-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
  end

  def author(operation:, attributes:)
    previewed = CatalogRelationshipService::OPERATIONS.include?(operation.to_s) || attributes.key?(:media)
    proposal = CatalogAuthoringService.preview(operation: operation, attributes: attributes) if previewed
    game_id = attributes[:game_id] || attributes[:id]
    game_id = CatalogAuthoringReadService.release(id: game_id).dig("canonical", "game_id") if operation == :correct_release
    revisions = proposal ? proposal.fetch("expected_revisions") : CatalogAuthoringReadService.scope(game_id: game_id).to_h { |state| [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ] }
    CatalogAuthoringService.call(operation: operation, attributes: attributes, expected_revisions: revisions,
      preview: proposal, reason: "Synthetic import correction", idempotency_key: SecureRandom.uuid)
  end

  it "preserves corrections and retains changed source metadata without correction audits or authored flags" do
    entries = [ { title: "Original (USA)", sha1: checksum(9001), size: 10, crc: "12345678" } ]
    import_entries(entries: entries)
    release = Release.sole
    game = release.game
    author(operation: :correct_game, attributes: { id: game.public_id, title: "Reviewed", title_aliases: [ "Searchable" ] })
    author(operation: :correct_release, attributes: { id: release.public_id, region: "Europe", revision: "Rev B" })
    author(operation: :correct_media, attributes: { sha1: release.sha1, size: 20 })
    audits = CatalogMutation.order(:id).map(&:attributes)
    fields = [ game.reload, release.reload, release.media_files.sole ].map(&:authored_fields)
    stale = CatalogAuthoringReadService.scope(game_id: game.public_id).to_h { |state| [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ] }
    result = import_entries(entries: [ entries.sole.merge(title: "Changed (Japan) (Rev 2)", size: 30, crc: "87654321") ])
    expect(game.reload).to have_attributes(title: "Reviewed", source_title: "Changed", title_aliases: [ "Searchable" ])
    expect(release.reload).to have_attributes(region: "Europe", revision: "Rev B", source_region: "Japan", source_revision: "Rev 2")
    file = release.media_files.sole.reload
    expect(file).to have_attributes(size: 20, source_size: 30, crc32: "87654321", source_crc32: "87654321")
    expect(CatalogAuthoringReadService.record(file).fetch("source")).to include("source_size" => 30)
    expect([ game, release, file ].map(&:authored_fields)).to eq(fields)
    expect(result.fetch(:divergences)).to include(
      { type: "game", id: game.public_id, field: "title", source_value: "Changed", effective_value: "Reviewed" },
      { type: "release", id: release.public_id, field: "region", source_value: "Japan", effective_value: "Europe" },
      { type: "media", id: file.sha1, field: "size", source_value: 30, effective_value: 20 })
    expect(CatalogMutation.order(:id).map(&:attributes)).to eq(audits)
    expect do
      CatalogAuthoringService.call(operation: :correct_game, attributes: { id: game.public_id, title: "Stale" },
        expected_revisions: stale, reason: "Stale correction", idempotency_key: "stale")
    end.to raise_error(CatalogAuthoringService::Conflict)
    before = snapshot
    import_entries(entries: [ entries.sole.merge(title: "Changed (Japan) (Rev 2)", size: 30, crc: "87654321") ])
    expect(snapshot).to eq(before)
  end

  it "keeps fallback merge titles and original identity provenance through chained merges and retired mappings" do
    entries = [ { title: "Adventure (USA)", sha1: checksum(9001) }, { title: "Zelda (USA)", sha1: checksum(9002) } ]
    import_entries(entries: entries)
    original = Release.find_by!(sha1: checksum(9001)).game
    target = Release.find_by!(sha1: checksum(9002)).game
    key = original.game_identities.sole
    author(operation: :merge_games, attributes: { id: original.public_id, into_game_id: target.public_id })
    result = import_entries(entries: entries)
    expect(target.reload.title).to eq("Zelda")
    expect(original.reload.title).to eq("Adventure")
    expect(key.reload.game).to eq(original)
    expect(result.fetch(:divergences)).to include(hash_including(type: "release", field: "game_id", source_value: original.public_id, effective_value: target.public_id))
    final = create(:game, title: "Final")
    author(operation: :merge_games, attributes: { id: target.public_id, into_game_id: final.public_id })
    mapping = CatalogMappingService.new(text: "#{original.public_id} New source title\n  #{checksum(9001)}\n").mappings
    import_entries(entries: [ entries.first ], mappings: mapping)
    expect(original.reload).to have_attributes(title: "Adventure", source_title: "New source title", retired_into_game_id: target.id)
    expect(target.reload).to have_attributes(title: "Zelda", source_title: "Zelda", retired_into_game_id: final.id)
    expect(final.reload).to have_attributes(title: "Final", source_title: nil)
    expect(Release.distinct.pluck(:game_id)).to eq([ final.id ])
    expect(key.reload.game).to eq(original)
  end

  it "preserves reassignment and explicit restore selections when source grouping changes" do
    entries = [ { title: "Source (USA)", sha1: checksum(9001) }, { title: "Source (Europe)", sha1: checksum(9002) }, { title: "Target", sha1: checksum(9003) } ]
    import_entries(entries: entries)
    moving = Release.find_by!(sha1: checksum(9001))
    source = moving.game
    target = Release.find_by!(sha1: checksum(9003)).game
    author(operation: :reassign_release, attributes: { id: moving.public_id, game_id: target.public_id })
    import_entries(entries: [ entries.first.merge(title: "New Source (Japan)"), entries.last ])
    expect(moving.reload.game).to eq(target)
    expect(source.reload.title).to eq("Source")
    expect(target.reload.title).to eq("Target")
    author(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    author(operation: :restore_game, attributes: { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ moving.public_id ], title: "Restored" })
    result = import_entries(entries: entries)
    expect(moving.reload.game).to eq(source)
    expect(source.reload.title).to eq("Restored")
    expect(Release.find_by!(sha1: checksum(9002)).game).to eq(target)
    expect(result.fetch(:divergences)).to include(hash_including(field: "title", effective_value: "Restored"))
  end

  it "keeps detached checksums unattached and refuses secondary memberships before writes" do
    entry = { title: "Original", sha1: checksum(9001) }
    import_entries(entries: [ entry ])
    release = Release.sole
    file = create(:media_file, sha1: checksum(9002))
    author(operation: :correct_release, attributes: { id: release.public_id, media: [ { key: "replacement", position: 1, role: "game", sha1: file.sha1 } ] })
    result = import_entries(entries: [ entry.merge(size: 64) ])
    expect(Release.count).to eq(1)
    expect(MediaFile.find_by!(sha1: checksum(9001)).releases).to be_empty
    expect(result.fetch(:divergences)).to include(type: "media", id: checksum(9001), field: "membership", source_value: "single release", effective_value: [])
    author(operation: :correct_release, attributes: { id: release.public_id, media: [
      { key: "replacement", position: 1, role: "game", sha1: file.sha1 }, { key: "secondary", position: 2, role: "game", sha1: checksum(9001) }
    ] })
    before = snapshot
    expect { import_entries(entries: [ entry ]) }.to raise_error(CatalogImportService::IdentityConflict, /#{release.public_id}.*#{checksum(9001)}.*multi-disk/)
    expect(snapshot).to eq(before)
  end

  it "invalidates stale previews on source-only changes and rolls invalid resulting configurations back" do
    entry = { title: "Original (USA)", sha1: checksum(9001), size: 10 }
    import_entries(entries: [ entry ])
    release = Release.sole
    author(operation: :correct_media, attributes: { sha1: release.sha1, size: 20 })
    attributes = { sha1: release.sha1, size: 40 }
    preview = CatalogAuthoringService.preview(operation: :correct_media, attributes: attributes)
    import_entries(entries: [ entry.merge(size: 30) ])
    expect do
      CatalogAuthoringService.call(operation: :correct_media, attributes: attributes, preview: preview,
        expected_revisions: preview.fetch("expected_revisions"), reason: "Stale preview", idempotency_key: "stale-preview")
    end.to raise_error(CatalogAuthoringService::Conflict)
    before = snapshot
    expect { import_entries(entries: [ entry.merge(crc: "invalid"), { title: "New", sha1: checksum(9002) } ]) }.to raise_error(ActiveRecord::RecordInvalid, /Crc32/)
    expect(snapshot).to eq(before)
  end

  it "bounds bulk writes to 500 rows while reporting no divergences on new imports" do
    [ Game, GameIdentity, Release, MediaFile, ReleaseMedium ].each do |model|
      method = model.in?([ Release, MediaFile ]) ? :upsert_all : :insert_all!
      allow(model).to receive(method).and_wrap_original do |original, rows, **options|
        expect(rows.size).to be <= 500
        original.call(rows, **options)
      end
    end
    result = import_entries(entries: Array.new(501) { |index| { title: "Synthetic #{index}", sha1: checksum(10000 + index) } })
    expect(Release.count).to eq(501)
    expect(result.fetch(:divergences)).to eq([])
  end
end
