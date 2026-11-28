require "rails_helper"
require_relative "../support/catalog_helpers"

RSpec.describe CatalogImportService do
  include CatalogHelpers

  it "preserves an authored exact-edition profile and evidence through a supported reimport" do
    entries = [ { title: "Synthetic (USA)", sha1: checksum(1), size: 16384 } ]
    import_entries(entries: entries, system: "snes")
    release = Release.sole
    profile = build(:controller_profile, binding: { "system" => "snes", "region" => "USA", "revision" => nil })
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Synthetic Owner")
    CatalogAuthoringService.call(operation: :correct_release, attributes: { id: release.public_id, controller_profile: profile },
      expected_revisions: { "game:#{release.game.public_id}" => 0, "release:#{release.public_id}" => 0 },
      reason: "Synthetic evidence", idempotency_key: "import-profile")
    original = release.reload.attributes
    history = CatalogMutation.sole.attributes
    import_entries(entries: [ entries.sole.merge(size: 32768) ], system: "snes")
    expect(release.reload.attributes.except("updated_at", "authoring_revision")).to eq(original.except("updated_at", "authoring_revision"))
    expect(release.authoring_revision).to eq(original.fetch("authoring_revision") + 1)
    expect(release.media_files.sole.size).to eq(32768)
    expect(CatalogMutation.sole.attributes).to eq(history)
    before = snapshot
    expect { import_entries(entries: [ entries.sole.merge(title: "Synthetic (Europe)") ], system: "snes") }.to raise_error(described_class::IdentityConflict, /binding/)
    expect(snapshot).to eq(before)
  end

  around do |example|
    Dir.mktmpdir("catalog-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  it "imports media metadata and preserves media identities and timestamps on repeat imports" do
    entries = [ { title: "Example (USA)", sha1: checksum(1), filename: "example.NES", size: 16384, crc: "ABCDEF12", md5: "A" * 32 } ]
    import_entries(entries: entries)
    release = Release.sole
    expect(release.attributes.slice("source_title", "source_system", "source_region", "source_revision")).to eq("source_title" => "Example (USA)", "source_system" => "nes", "source_region" => "USA", "source_revision" => nil)
    expect(release.game.source_title).to eq("Example")
    expect(release.release_media.sole.attributes.slice("key", "position", "label", "role")).to eq("key" => "main", "position" => 1, "label" => nil, "role" => "game")
    expect(MediaFile.sole.attributes.slice("sha1", "size", "format", "crc32", "md5")).to eq("sha1" => checksum(1), "size" => 16384, "format" => "nes", "crc32" => "abcdef12", "md5" => "a" * 32)
    before = snapshot
    import_entries(entries: entries)
    expect(snapshot).to eq(before)
    expect { import_entries(entries: [ entries.first.merge(size: 32768) ]) }.to change { release.reload.updated_at }
    expect(MediaFile.sole.size).to eq(32768)
    expect(release.public_id).to eq(before[1].sole.fetch("public_id"))
  end

  it "leaves curated multi-disk and shared releases intact when an offline import encounters their files" do
    import_entries(entries: [ { title: "Example", sha1: checksum(1) } ])
    release = Release.sole
    create(:release_medium, release: release)
    before = snapshot
    expect { import_entries(entries: [ { title: "Example", sha1: checksum(1) } ]) }.to raise_error(described_class::IdentityConflict, /multi-disk or shared/)
    expect(snapshot).to eq(before)
  end

  it "groups regional/revision and NES headered/unheadered releases, normalizes SHA-1 and repeats without writes" do
    entries = [
      { title: "Example (USA) (Rev 1)", checksums: [ "A" * 40, "b" * 40 ], filename: "example.nes" },
      { title: "Example (Japan, USA) (v1.3)", sha1: "c" * 40 },
      { title: "Example (Europe)", sha1: "d" * 40 },
      { title: "Example (World)", sha1: "e" * 40 },
      { title: "No checksum", sha1: "invalid" }
    ]
    result = import_entries(entries: entries)
    expect(result[:games]).to eq(created: 1, updated: 0, unchanged: 0, skipped: 1)
    expect(result[:releases]).to eq(created: 5, updated: 0, unchanged: 0, skipped: 1)
    expect(result[:skipped_reasons]).to eq([ "missing or invalid SHA-1 for No checksum" ])
    expect(Release.order(:sha1).pluck(:region, :revision)).to eq([ [ "USA", "Rev 1" ], [ "USA", "Rev 1" ], [ "Japan, USA", "v1.3" ], [ "Europe", nil ], [ "World", nil ] ])
    expect(Release.distinct.pluck(:game_id).size).to eq(1)
    expect(Game.sole.title).to eq("Example")
    before = snapshot
    repeat = import_entries(entries: entries.reverse)
    expect(snapshot).to eq(before)
    expect(repeat[:releases]).to eq(created: 0, updated: 0, unchanged: 5, skipped: 1)
    expect(repeat[:games][:unchanged]).to eq(1)
  end

  it "keeps curated Tetris identities distinct and shares only explicitly mapped cross-system releases" do
    mappings = CatalogMappingService.new(text: "tetris Tetris\n  #{checksum(1)}\ntetris-tengen Tetris (Tengen)\n  #{checksum(2)}\npac-man Pac-Man\n  #{checksum(3)}\n  #{checksum(4)}\n").mappings
    import_entries(entries: [ { title: "Tetris (USA)", sha1: checksum(1) }, { title: "Tetris (USA) (Tengen)", sha1: checksum(2) }, { title: "Pac-Man (USA)", sha1: checksum(3) }, { title: "Pac-Man (Europe)", sha1: checksum(5) } ], mappings: mappings)
    import_entries(entries: [ { title: "Pac-Man (Japan)", sha1: checksum(4) }, { title: "Pac-Man (World)", sha1: checksum(6) } ], system: "gb", mappings: mappings)
    expect(Release.find_by!(sha1: checksum(1)).game.public_id).to eq("tetris")
    expect(Release.find_by!(sha1: checksum(2)).game.title).to eq("Tetris (Tengen)")
    expect(Release.find_by!(sha1: checksum(3)).game).to eq(Release.find_by!(sha1: checksum(4)).game)
    expect(Release.where(sha1: [ checksum(3), checksum(5), checksum(6) ]).distinct.pluck(:game_id).size).to eq(3)
  end

  it "preserves case, punctuation and unknown annotations as exact identity discriminators, with NFC and collapsed spaces" do
    names = [ "A-B (USA)", "A B (USA)", "A B (Prototype)", "A B (Beta)", "a b (USA)", "Cafe\u0301   Noir (Europe)", "Café Noir (Japan)" ]
    import_entries(entries: names.each_with_index.map { |title, i| { title: title, sha1: checksum(i + 1) } })
    expect(Game.count).to eq(6)
    expect(Release.find_by!(sha1: checksum(3)).attributes.slice("region", "revision")).to eq("region" => nil, "revision" => nil)
    expect(Release.find_by!(sha1: checksum(6)).game).to eq(Release.find_by!(sha1: checksum(7)).game)
    expect(Game.where(title: "A B").pluck(:public_id).uniq.size).to eq(3)
  end

  it "keeps game IDs and all exact aliases through partial corrections, absent releases and deterministic title changes" do
    import_entries(entries: [ { title: "Zed (USA)", sha1: checksum(1) }, { title: "Zed (Europe)", sha1: checksum(2) } ])
    game = Game.sole
    original_id = game.public_id
    import_entries(entries: [ { title: "Alpha (USA)", sha1: checksum(1) } ])
    expect(game.reload.title).to eq("Alpha")
    import_entries(entries: [ { title: "Zed (Japan)", sha1: checksum(3) } ])
    expect(Game.sole.public_id).to eq(original_id)
    expect(Release.count).to eq(3)
    import_entries(entries: [ { title: "Omega (USA)", sha1: checksum(1) } ])
    expect(game.reload.title).to eq("Omega")
    import_entries(entries: [ { title: "Alpha (World)", sha1: checksum(4) } ])
    expect(Game.sole.title).to eq("Alpha")
    expect(GameIdentity.count).to eq(3)
  end

  it "fails conflicting aliases or curated reassignment before any write" do
    import_entries(entries: [ { title: "One (USA)", sha1: checksum(1) }, { title: "Two (USA)", sha1: checksum(2) } ])
    before = snapshot
    expect { import_entries(entries: [ { title: "Two (Europe)", sha1: checksum(1) }, { title: "New", sha1: checksum(3) } ]) }.to raise_error(described_class::IdentityConflict, /multiple games/)
    mapping = CatalogMappingService.new(text: "new-id New\n  #{checksum(1)}").mappings
    expect { import_entries(entries: [ { title: "One", sha1: checksum(1) } ], mappings: mapping) }.to raise_error(described_class::IdentityConflict, /cannot move/)
    expect(snapshot).to eq(before)
  end

  it "refuses generated ID collisions rather than joining games" do
    create(:game, public_id: CatalogNameService.public_id(**CatalogNameService.attributes(title: "One", system: "nes").slice(:key, :title), system: "nes"))
    expect { import_entries(entries: [ { title: "One", sha1: checksum(1) } ]) }.to raise_error(described_class::IdentityConflict, /public ID/)
    expect(Release.count).to eq(0)
  end

  it "rolls back all bulk writes when a system write fails" do
    allow(Release).to receive(:upsert_all).and_raise(ActiveRecord::StatementInvalid, "write failed")
    expect { import_entries(entries: [ { title: "One", sha1: checksum(1) } ]) }.to raise_error(ActiveRecord::StatementInvalid)
    expect([ Game.count, Release.count, GameIdentity.count ]).to eq([ 0, 0, 0 ])
  end

  it "parses and validates before opening its write transaction" do
    path = write_dat(entries: [ { title: "One", sha1: checksum(1) } ])
    File.open(path, "a") { |file| file.write("game ( name \"unfinished\"") }
    expect(ApplicationRecord).not_to receive(:transaction)
    expect { described_class.import(path: path, system: "nes", mappings: {}) }.to raise_error(CatalogDatService::InvalidDat)
  end

  it "preserves fixed seed IDs and imported metadata across seeds, imports and reseeding" do
    load Rails.root.join("db/seeds.rb")
    import_entries(entries: [ { title: "uCity (World) (v1.3)", sha1: described_class::SEEDS.key("ucity") } ], system: "gbc")
    import_entries(entries: [ { title: "Tobu Tobu Girl (World)", sha1: described_class::SEEDS.key("tobu-tobu-girl") } ], system: "gb")
    before = snapshot
    load Rails.root.join("db/seeds.rb")
    expect(snapshot).to eq(before)
    expect(Release.includes(:game).order(:system).map { |release| [ release.game.public_id, release.game.title, release.system, release.region, release.revision ] }).to eq([ [ "tobu-tobu-girl", "Tobu Tobu Girl", "gb", "World", nil ], [ "ucity", "uCity", "gbc", "World", "v1.3" ] ])
    expect(Game.order(:public_id).pluck(:screenshot_licence)).to eq([ "CC-BY-4.0", "CC-BY-SA-4.0" ])
  end

  it "assigns the same fixed seed IDs when importing into an empty database" do
    import_entries(entries: [ { title: "uCity (World) (v1.3)", sha1: described_class::SEEDS.key("ucity") } ], system: "gbc")
    expect(Game.sole.public_id).to eq("ucity")
    import_entries(entries: [ { title: "Tobu Tobu Girl (World)", sha1: described_class::SEEDS.key("tobu-tobu-girl") } ], system: "gb")
    expect(Game.order(:public_id).pluck(:public_id)).to eq([ "tobu-tobu-girl", "ucity" ])
  end
end
