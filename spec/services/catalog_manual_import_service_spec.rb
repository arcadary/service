require "rails_helper"
require "open3"

RSpec.describe CatalogManualImportService do
  around do |example|
    Dir.mktmpdir("manual-catalog-", Rails.root.join("tmp")) do |folder|
      @path = Pathname.new(folder).join("operation.json")
      example.run
    end
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
  end

  def apply(operation:, attributes:, expected_revisions: {}, preview: nil, key: SecureRandom.uuid)
    @path.write(JSON.generate(operation: operation, attributes: attributes, expected_revisions: expected_revisions,
      preview: preview, reason: "Synthetic offline import", idempotency_key: key))
    described_class.call(path: @path)
  end

  def preview(operation:, attributes:)
    @path.write(JSON.generate(operation: operation, attributes: attributes))
    described_class.call(path: @path, preview: true)
  end

  def revisions(game_id:)
    scope = @path.dirname.join("scope.json")
    scope.write(JSON.pretty_generate(CatalogAuthoringReadService.scope(game_id: game_id)))
    JSON.parse(scope.read).to_h do |state|
      [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ]
    end
  end

  def merge(source:, target:)
    attributes = { id: source.public_id, into_game_id: target.public_id }
    proposal = preview(operation: :merge_games, attributes: attributes)
    apply(operation: :merge_games, attributes: attributes, expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
  end

  it "uses offline scope reads for corrections and release creation after a chained merge, then replays the exact envelope" do
    oldest = create(:game)
    middle = create(:game)
    current = create(:game)
    release = create(:release, game: oldest)
    merge(source: oldest, target: middle)
    merge(source: middle, target: current)
    scope = revisions(game_id: oldest.public_id)
    expect(scope.keys).to match_array([ "game:#{oldest.public_id}", "game:#{middle.public_id}", "game:#{current.public_id}", "release:#{release.public_id}" ])
    apply(operation: :correct_game, attributes: { id: oldest.public_id, title: "Offline title", title_aliases: [ "Other title" ] }, expected_revisions: scope)
    game_id = CatalogAuthoringReadService.release(id: release.public_id).dig("canonical", "game_id")
    apply(operation: :correct_release, attributes: { id: release.public_id, region: "Europe" }, expected_revisions: revisions(game_id: game_id))
    result = apply(operation: :create_release, attributes: { game_id: oldest.public_id, system: "gb", media: [ { key: "main", position: 1, role: "game", sha1: "f" * 40 } ] }, expected_revisions: revisions(game_id: oldest.public_id), key: "offline-create")
    envelope = @path.read
    expect(current.reload.title).to eq("Offline title")
    expect(Release.find_by!(sha1: "f" * 40).game).to eq(current)
    apply(operation: :correct_game, attributes: { id: oldest.public_id, title: "Later title" }, expected_revisions: revisions(game_id: oldest.public_id))
    @path.write(envelope)
    expect(described_class.call(path: @path)).to eq(result)
    @path.write(JSON.generate(JSON.parse(envelope).merge("reason" => "Different request")))
    expect { described_class.call(path: @path) }.to raise_error(CatalogAuthoringService::Conflict, /different request/)
  end

  it "returns complete read-only relationship and media previews and never replaces a supplied stale preview" do
    source = create(:game)
    release = create(:release, game: source)
    target = create(:game)
    attributes = { id: release.public_id, game_id: target.public_id }
    proposal = preview(operation: :reassign_release, attributes: attributes)
    expect(CatalogMutation.count).to eq(0)
    expect(release.reload.game).to eq(source)
    expect(proposal).to eq(CatalogAuthoringService.preview(operation: :reassign_release, attributes: attributes))
    apply(operation: :correct_game, attributes: { id: target.public_id, title: "Changed" }, expected_revisions: revisions(game_id: target.public_id))
    expect do
      apply(operation: :reassign_release, attributes: attributes, expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
    end.to raise_error(CatalogAuthoringService::Conflict)
    proposal = preview(operation: :reassign_release, attributes: attributes)
    apply(operation: :reassign_release, attributes: attributes, expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
    merge(source: source, target: target)
    proposal = preview(operation: :restore_game, attributes: { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ release.public_id ] })
    apply(operation: :restore_game, attributes: proposal.fetch("attributes"), expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
    proposal = preview(operation: :correct_media, attributes: { sha1: release.sha1, size: 64 })
    apply(operation: :correct_media, attributes: proposal.fetch("attributes"), expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
    media = CatalogAuthoringReadService.release(id: release.public_id).dig("canonical", "media")
    media.first["label"] = "Reviewed cartridge"
    proposal = preview(operation: :correct_release, attributes: { id: release.public_id, media: media })
    result = apply(operation: :correct_release, attributes: proposal.fetch("attributes"), expected_revisions: proposal.fetch("expected_revisions"), preview: proposal)
    expect(result.fetch("preview")).to eq(proposal)
    expect(release.reload.release_media.sole.label).to eq("Reviewed cartridge")
  end

  it "uses the same validation, admin requirement and atomic rollback as direct authoring" do
    apply(operation: :create_game, attributes: { id: "offline", title: "Offline" })
    apply(operation: :create_media, attributes: { sha1: "a" * 40, size: 64 })
    game = Game.find_by!(public_id: "offline")
    attributes = { game_id: game.public_id, system: "c64", startup: { schema: 1, boot: "missing", drives: {} }, media: [ { key: "main", position: 1, role: "game", sha1: "b" * 40 } ] }
    expect { apply(operation: :create_release, attributes: attributes, expected_revisions: revisions(game_id: game.public_id)) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(MediaFile.exists?(sha1: "b" * 40)).to be(false)
    expect(game.reload.authoring_revision).to eq(1)
    expect(CatalogMutation.count).to eq(2)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "synthetic failure")
    expect { apply(operation: :correct_game, attributes: { id: game.public_id, title: "Failed" }, expected_revisions: revisions(game_id: game.public_id)) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(game.reload.title).to eq("Offline")
    expect(CatalogMutation.count).to eq(2)
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("")
    expect { described_class.call(path: @path) }.to raise_error(CatalogAuthoringService::MissingAdminName)
  end

  it "prints a complete preview offline and exits nonzero with a JSON failure for an invalid envelope" do
    @path.write(JSON.generate(operation: "create_game", attributes: { id: "offline", title: "Offline" }, expected_revisions: {}, reason: "Synthetic", idempotency_key: "bad", sql: "unsupported"))
    _, error, status = Open3.capture3(RbConfig.ruby, "bin/rails", "catalog:apply[#{@path}]")
    expect(status.exitstatus).not_to eq(0)
    expect(JSON.parse(error)).to include("error" => "CatalogAuthoringService::InvalidInput")
    @path.write(JSON.generate(operation: "correct_media", attributes: { sha1: "a" * 40, size: 64 }))
    script = "require_relative './config/environment'; ApplicationRecord.transaction do; MediaFile.create!(sha1: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); ARGV.replace([#{JSON.generate("catalog:preview[#{@path}]")}]); load './bin/rails'; raise ActiveRecord::Rollback; end"
    output, error, status = Open3.capture3(RbConfig.ruby, "-e", script)
    expect(status.exitstatus).to eq(0), error
    expect(JSON.parse(output)).to include("operation" => "correct_media", "expected_revisions" => { "media:#{'a' * 40}" => 0 })
  end
end
