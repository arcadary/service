require "rails_helper"

RSpec.describe "Catalog relationship authoring" do
  let(:source) { create(:game, title: "Original", title_aliases: [ "Alternate", "Shared" ], source_title: "Imported original", catalog_curated: true) }
  let(:target) { create(:game, title: "Canonical", title_aliases: [ "Shared" ], source_title: "Imported canonical") }
  let(:release) { create(:release, game: source, system: "c64", source_title: "Release source") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
  end

  def preview(operation:, attributes:)
    CatalogAuthoringService.preview(operation: operation, attributes: attributes)
  end

  def apply(operation:, attributes:, proposal: preview(operation: operation, attributes: attributes), revisions: proposal.fetch("expected_revisions"), key: SecureRandom.uuid)
    CatalogAuthoringService.call(operation: operation, attributes: attributes, preview: proposal, expected_revisions: revisions,
      reason: "Synthetic relationship correction", idempotency_key: key)
  end

  def media_attributes(release:)
    CatalogAuthoringReadService.release(id: release.public_id).dig("canonical", "media")
  end

  it "previews complete raw state, resolutions, item identities and revisions without credentials or writes" do
    release
    key = create(:game_identity, game: source)
    attributes = { id: source.public_id, into_game_id: target.public_id }
    before = [ Game.all.map(&:attributes), Release.all.map(&:attributes), MediaFile.all.map(&:attributes) ]
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return(nil)
    proposal = preview(operation: :merge_games, attributes: attributes)
    expect([ Game.all.map(&:attributes), Release.all.map(&:attributes), MediaFile.all.map(&:attributes) ]).to eq(before)
    expect(CatalogMutation.count).to eq(0)
    expect(proposal.fetch("requested_ids")).to eq("id" => source.public_id, "into_game_id" => target.public_id)
    expect(proposal.dig("resolutions", "before", source.public_id)).to eq(source.public_id)
    expect(proposal.dig("resolutions", "after", source.public_id)).to eq(target.public_id)
    expect(proposal.fetch("expected_revisions").keys).to match_array([ "game:#{source.public_id}", "game:#{target.public_id}", "release:#{release.public_id}", "media:#{release.sha1}" ])
    expect(proposal.fetch("affected_items")).to include({ "type" => "membership", "id" => [ release.public_id, "main" ] }, { "type" => "alias", "id" => [ target.public_id, "Original" ] }, { "type" => "importer_key", "id" => key.key })
    retained = proposal.fetch("after").find { |state| state.fetch("id") == source.public_id }
    expect(retained.fetch("canonical")).to eq("title" => "Original", "title_aliases" => [ "Alternate", "Shared" ])
    expect(retained.dig("identity", "canonical_game_id")).to eq(target.public_id)
  end

  it "reassigns only the selected release and preserves checksums, IDs and provenance" do
    sibling = create(:release, game: source)
    destination = create(:release, game: target)
    identity = release.slice(:public_id, :sha1, :source_title)
    result = apply(operation: :reassign_release, attributes: { id: release.public_id, game_id: target.public_id })
    expect(release.reload.game).to eq(target)
    expect(release.slice(:public_id, :sha1, :source_title)).to eq(identity)
    expect(sibling.reload.game).to eq(source)
    expect(result.fetch("records").map { |state| state.fetch("id") }).to include(source.public_id, target.public_id, release.public_id, sibling.public_id, destination.public_id)
    expect(result.fetch("records").map { |state| state.fetch("authoring_revision") }.uniq).to eq([ 1 ])
    expect(source.reload.retired_into_game_id).to be_nil
    expect(CatalogMutation.count).to eq(1)
  end

  it "retains merge metadata and key ownership, deduplicates aliases exactly and permits curated/fallback grouping" do
    release
    key = create(:game_identity, game: source)
    target.update!(title_aliases: [ "Shared", "alternate", "Canonical" ])
    result = apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    expect(source.reload).to have_attributes(retired_into_game_id: target.id, title: "Original", title_aliases: [ "Alternate", "Shared" ], source_title: "Imported original", catalog_curated: true)
    expect(target.reload).to have_attributes(title: "Canonical", source_title: "Imported canonical", catalog_curated: false)
    expect(target.title_aliases).to eq([ "Shared", "alternate", "Original", "Alternate" ])
    expect(key.reload.game).to eq(source)
    expect(release.reload.game).to eq(target)
    raw = result.fetch("records").find { |state| state.fetch("id") == source.public_id }
    expect(raw.dig("identity", "importer_keys")).to eq([ key.key ])
    audit = CatalogMutation.last.record_changes.find { |change| change.dig("after", "id") == source.public_id }
    expect(audit.dig("before", "identity", "state")).to eq("active")
    expect(audit.dig("after", "identity", "state")).to eq("retired")
  end

  it "resolves old IDs for grouping, corrections, creation and reassignment with actual revision keys" do
    release
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    third = create(:game, title: "Final")
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: third.public_id })
    expect(CatalogAuthoringReadService.game(id: source.public_id).fetch("id")).to eq(third.public_id)
    expect(CatalogAuthoringReadService.record(source.reload).dig("identity", "retired_into_game_id")).to eq(target.public_id)
    scope = CatalogAuthoringReadService.scope(game_id: source.public_id)
    revisions = scope.to_h { |state| [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ] }
    expect do
      CatalogAuthoringService.call(operation: :correct_game, attributes: { id: source.public_id, title: "Corrected final" },
        expected_revisions: revisions.except("game:#{third.public_id}"), reason: "Synthetic old ID correction", idempotency_key: SecureRandom.uuid)
    end.to raise_error(CatalogAuthoringService::Conflict)
    CatalogAuthoringService.call(operation: :correct_game, attributes: { id: source.public_id, title: "Corrected final" },
      expected_revisions: revisions, reason: "Synthetic old ID correction", idempotency_key: SecureRandom.uuid)
    scope = CatalogAuthoringReadService.scope(game_id: source.public_id)
    revisions = scope.to_h { |state| [ "#{state.fetch('type')}:#{state.fetch('id')}", state.fetch("authoring_revision") ] }
    CatalogAuthoringService.call(operation: :create_release, attributes: { game_id: source.public_id, system: "gb", media: [ { key: "main", position: 1, role: "game", sha1: "f" * 40 } ] },
      expected_revisions: revisions, reason: "Synthetic old ID creation", idempotency_key: SecureRandom.uuid)
    expect(Release.last.game).to eq(third)
    expect(third.reload.title).to eq("Corrected final")
    outsider = create(:release)
    apply(operation: :reassign_release, attributes: { id: outsider.public_id, game_id: source.public_id })
    expect(outsider.reload.game).to eq(third)
  end

  it "rejects resolved self-grouping and incompatible screenshot licences during preview and apply" do
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    expect { preview(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id }) }.to raise_error(CatalogAuthoringService::Conflict, /same game/)
    current = create(:release, game: target)
    expect { apply(operation: :reassign_release, attributes: { id: current.public_id, game_id: source.public_id }) }.to raise_error(CatalogAuthoringService::Conflict, /same game/)
    other = create(:game, screenshot_licence: "CC0")
    expect { preview(operation: :merge_games, attributes: { id: target.public_id, into_game_id: other.public_id }) }.to raise_error(CatalogAuthoringService::Conflict, /licences/)
    expect { preview(operation: :reassign_release, attributes: { id: current.public_id, game_id: other.public_id }) }.to raise_error(CatalogAuthoringService::Conflict, /licences/)
    expect(CatalogMutation.count).to eq(1)
  end

  it "rejects missing previews, stale or unrelated revisions and a changed complete affected set" do
    attributes = { id: release.public_id, game_id: target.public_id }
    proposal = preview(operation: :reassign_release, attributes: attributes)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: nil, revisions: proposal.fetch("expected_revisions")) }.to raise_error(CatalogAuthoringService::Conflict, /preview/)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal, revisions: {}) }.to raise_error(CatalogAuthoringService::Conflict, /revisions/)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal, revisions: proposal.fetch("expected_revisions").merge("game:unrelated" => 0)) }.to raise_error(CatalogAuthoringService::InvalidInput)
    target.update!(authoring_revision: 1)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict)
    proposal = preview(operation: :reassign_release, attributes: attributes)
    create(:release, game: target)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict)
    expect(release.reload.game).to eq(source)
    expect(CatalogMutation.count).to eq(0)
  end

  it "detects alias and importer-key ownership changes even without revision changes" do
    attributes = { id: release.public_id, game_id: target.public_id }
    key = create(:game_identity, game: source)
    proposal = preview(operation: :reassign_release, attributes: attributes)
    target.update!(title_aliases: [ "Changed externally" ])
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict, /preview/)
    proposal = preview(operation: :reassign_release, attributes: attributes)
    key.update!(game: target)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict, /preview/)
    expect(CatalogMutation.count).to eq(0)
  end

  it "counts the before/after union exactly and refuses an applicable truncated or oversized preview" do
    source.update!(title_aliases: [])
    target.update!(title_aliases: Array.new(94) { |index| "Alias #{index}" })
    release
    create(:game_identity, game: source)
    attributes = { id: release.public_id, game_id: target.public_id }
    proposal = preview(operation: :reassign_release, attributes: attributes)
    expect(proposal.fetch("affected_items").size).to eq(100)
    truncated = proposal.merge("affected_items" => proposal.fetch("affected_items").first(99))
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: truncated) }.to raise_error(CatalogAuthoringService::Conflict)
    create(:game_identity, game: target)
    expect { preview(operation: :reassign_release, attributes: attributes) }.to raise_error(CatalogAuthoringService::InvalidInput, /100/)
    expect { apply(operation: :reassign_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::InvalidInput, /100/)
    expect(CatalogMutation.count).to eq(0)
  end

  it "counts newly gained aliases as distinct items on the after side of a merge" do
    source.update!(title_aliases: Array.new(49) { |index| "Alias #{index}" })
    target.update!(title_aliases: [])
    expect { preview(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id }) }.to raise_error(CatalogAuthoringService::InvalidInput, /100/)
    expect(source.reload.retired_into_game_id).to be_nil
  end

  it "restores the original ID and only selected releases with retained defaults and unchanged canonical aliases" do
    release
    sibling = create(:release, game: source)
    key = create(:game_identity, game: source)
    merge = apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    aliases = target.reload.title_aliases
    result = apply(operation: :restore_game, attributes: { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ release.public_id ] })
    expect(source.reload).to have_attributes(retired_into_game_id: nil, title: "Original", title_aliases: [ "Alternate", "Shared" ], source_title: "Imported original", catalog_curated: true)
    expect(release.reload.game).to eq(source)
    expect(sibling.reload.game).to eq(target)
    expect(target.reload.title_aliases).to eq(aliases)
    expect(key.reload.game).to eq(source)
    expect(result.fetch("records").map { |state| state.fetch("id") }).to include(source.public_id, target.public_id, release.public_id, sibling.public_id)
    expect(CatalogMutation.find(merge.fetch("audit_id")).result).to eq(merge)
    expect(CatalogMutation.count).to eq(2)
  end

  it "permits an empty restore and explicit title and canonical alias corrections without inferring an inverse" do
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    apply(operation: :restore_game, attributes: { id: source.public_id, canonical_game_id: target.public_id, release_ids: [], title: "Restored", title_aliases: [ "Restored alias" ], canonical_title_aliases: [ "Intentional" ] })
    expect(source.reload).to have_attributes(title: "Restored", title_aliases: [ "Restored alias" ], source_title: "Imported original")
    expect(target.reload.title_aliases).to eq([ "Intentional" ])
  end

  it "rejects restore after a chained merge, foreign release selection or unsupported metadata" do
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    attributes = { id: source.public_id, canonical_game_id: target.public_id, release_ids: [] }
    outsider = create(:release)
    expect { preview(operation: :restore_game, attributes: attributes.merge(release_ids: [ outsider.public_id ])) }.to raise_error(CatalogAuthoringService::Conflict)
    expect { preview(operation: :restore_game, attributes: attributes.merge(source_title: "Replacement")) }.to raise_error(CatalogAuthoringService::InvalidInput)
    third = create(:game)
    apply(operation: :merge_games, attributes: { id: target.public_id, into_game_id: third.public_id })
    expect { preview(operation: :restore_game, attributes: attributes) }.to raise_error(CatalogAuthoringService::Conflict, /direct retirement/)
    expect { preview(operation: :restore_game, attributes: attributes.merge(canonical_game_id: third.public_id)) }.to raise_error(CatalogAuthoringService::Conflict, /direct retirement/)
  end

  it "rolls a failed restore and audit back together, then retries and replays the saved result" do
    release
    apply(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    attributes = { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ release.public_id ] }
    proposal = preview(operation: :restore_game, attributes: attributes)
    target.update!(title_aliases: target.title_aliases + [ "Subsequent alias" ])
    expect { apply(operation: :restore_game, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict)
    proposal = preview(operation: :restore_game, attributes: attributes)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "synthetic failure")
    expect { apply(operation: :restore_game, attributes: attributes, proposal: proposal, key: "restore") }.to raise_error(ActiveRecord::StatementInvalid)
    expect(source.reload.retired_into_game_id).to eq(target.id)
    expect(release.reload.game).to eq(target)
    expect(CatalogMutation.count).to eq(1)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_call_original
    result = apply(operation: :restore_game, attributes: attributes, proposal: proposal, key: "restore")
    source.update!(authoring_revision: 10)
    expect(apply(operation: :restore_game, attributes: attributes, proposal: proposal, key: "restore")).to eq(result)
    expect(CatalogMutation.count).to eq(2)
  end

  it "validates a coupled media/startup correction and keeps surviving membership IDs and keys during swaps" do
    second = create(:release_medium, release: release)
    original = release.reload.release_media.index_by(&:key).transform_values(&:id)
    revision = ReleaseStartupService.revision(release: release)
    media = media_attributes(release: release).reverse.each_with_index.map { |medium, index| medium.merge("position" => index + 1) }
    attributes = { id: release.public_id, media: media, startup: { schema: 1, boot: second.key, drives: { "8" => second.key, "9" => "main" } } }
    apply(operation: :correct_release, attributes: attributes)
    expect(release.reload.release_media.map(&:key)).to eq([ second.key, "main" ])
    expect(release.release_media.index_by(&:key).transform_values(&:id)).to eq(original)
    expect(release.sha1).to eq(second.media_file.sha1)
    expect(ReleaseStartupService.revision(release: release)).not_to eq(revision)
  end

  it "rejects a media-only removal with dangling startup and accepts the combined replacement" do
    second = create(:release_medium, release: release)
    media = [ media_attributes(release: release).last.merge("position" => 1) ]
    attributes = { id: release.public_id, media: media }
    proposal = preview(operation: :correct_release, attributes: attributes)
    release.update!(startup: { schema: 1, boot: "main", drives: { "8" => "main", "9" => second.key } })
    expect { apply(operation: :correct_release, attributes: attributes, proposal: proposal) }.to raise_error(CatalogAuthoringService::Conflict)
    expect { preview(operation: :correct_release, attributes: attributes) }.to raise_error(ActiveRecord::RecordInvalid, /unknown medium key/)
    expect(release.reload.release_media.size).to eq(2)
    apply(operation: :correct_release, attributes: attributes.merge(startup: { schema: 1, boot: second.key, drives: { "8" => second.key } }))
    expect(release.reload.release_media.sole).to have_attributes(id: second.id, key: second.key)
    expect(CatalogMutation.count).to eq(1)
  end

  it "attaches existing checksums and corrects shared metadata under every containing game's revisions" do
    shared = create(:release)
    file = shared.media_files.sole
    media = media_attributes(release: release) + [ { key: "shared", position: 2, role: "save", sha1: file.sha1, size: 174848, format: "d64", crc32: "12345678", md5: "b" * 32, label: "Save disk" } ]
    proposal = preview(operation: :correct_release, attributes: { id: release.public_id, media: media })
    expect(proposal.fetch("expected_revisions").keys).to include("release:#{shared.public_id}", "game:#{shared.game.public_id}", "media:#{file.sha1}")
    apply(operation: :correct_release, attributes: { id: release.public_id, media: media }, proposal: proposal)
    expect(file.reload).to have_attributes(size: 174848, format: "d64", crc32: "12345678", md5: "b" * 32)
    expect(release.reload.release_media.last).to have_attributes(key: "shared", label: "Save disk", role: "save")
    expect(shared.reload.authoring_revision).to eq(1)
  end

  it "compensates shared metadata and media edits using current revisions and preserves earlier history" do
    shared = create(:release_medium, media_file: release.media_files.sole)
    revision = ReleaseStartupService.revision(release: release)
    first = apply(operation: :correct_media, attributes: { sha1: release.sha1, size: 123, format: "d64" })
    expect(first.fetch("records").map { |state| state.fetch("id") }).to include(release.public_id, shared.release.public_id)
    expect(ReleaseStartupService.revision(release: release.reload)).to eq(revision)
    apply(operation: :correct_media, attributes: { sha1: release.sha1, size: nil, format: nil })
    expect(release.media_files.sole).to have_attributes(size: nil, format: nil)
    expect(CatalogMutation.find(first.fetch("audit_id")).result).to eq(first)
  end

  it "rolls a coupled media change back on persistence failure and includes the preview in retry identity" do
    second = create(:release_medium, release: release)
    original_media = media_attributes(release: release)
    media = original_media.reverse.each_with_index.map { |medium, index| medium.merge("position" => index + 1) }
    attributes = { id: release.public_id, media: media }
    proposal = preview(operation: :correct_release, attributes: attributes)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "synthetic failure")
    expect { apply(operation: :correct_release, attributes: attributes, proposal: proposal, key: "media") }.to raise_error(ActiveRecord::StatementInvalid)
    expect(release.reload.release_media.map(&:key)).to eq([ "main", second.key ])
    expect(release.authoring_revision).to eq(0)
    expect(CatalogMutation.count).to eq(0)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_call_original
    result = apply(operation: :correct_release, attributes: attributes, proposal: proposal, key: "media")
    apply(operation: :correct_media, attributes: { sha1: release.reload.sha1, size: 10 })
    expect(apply(operation: :correct_release, attributes: attributes, proposal: proposal, key: "media")).to eq(result)
    expect { apply(operation: :correct_release, attributes: attributes, proposal: proposal.merge("after" => []), key: "media") }.to raise_error(CatalogAuthoringService::Conflict, /different request/)
    apply(operation: :correct_release, attributes: { id: release.public_id, media: original_media })
    expect(release.reload.release_media.map(&:key)).to eq([ "main", second.key ])
    expect(CatalogMutation.find(result.fetch("audit_id")).result).to eq(result)
  end
end
