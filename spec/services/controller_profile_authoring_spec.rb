require "rails_helper"

RSpec.describe CatalogAuthoringService, "controller profiles" do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Synthetic Owner")
  end

  let(:game) { create(:game) }
  let(:release) { create(:release, game: game, system: "snes") }
  let(:profile) { build(:controller_profile) }

  def author(attributes:, operation: :correct_release, revisions: nil, key: SecureRandom.uuid, preview: nil)
    revisions ||= CatalogAuthoringReadService.scope(game_id: game.public_id).to_h { |state| [ "#{state['type']}:#{state['id']}", state['authoring_revision'] ] }
    described_class.call(operation: operation, attributes: attributes, expected_revisions: revisions,
      reason: "Synthetic profile authoring", idempotency_key: key, preview: preview)
  end

  it "creates a profile, replaces it, clears it and retains exact retry results and evidence in audits" do
    attributes = { game_id: game.public_id, system: "snes", controller_profile: profile,
      media: [ { sha1: "f" * 40, key: "main", position: 1, role: "game" } ] }
    result = author(operation: :create_release, attributes: attributes, revisions: { "game:#{game.public_id}" => 0 }, key: "create-profile")
    created = Release.find_by!(sha1: "f" * 40)
    expect(author(operation: :create_release, attributes: attributes, revisions: { "game:#{game.public_id}" => 0 }, key: "create-profile")).to eq(result)
    expect(created.authored_fields).to include("controller_profile")
    replacement = profile.merge("prompts" => [])
    author(attributes: { id: created.public_id, controller_profile: replacement })
    author(attributes: { id: created.public_id, controller_profile: nil })
    expect(created.reload.controller_profile).to be_nil
    expect(created.authored_fields).to include("controller_profile")
    changes = CatalogMutation.order(:id).map { |entry| entry.record_changes.find { |change| change.dig("after", "id") == created.public_id } }
    expect(changes.map { |change| change.dig("after", "canonical", "controller_profile") }).to eq([ profile, replacement, nil ])
    expect(changes.last.dig("before", "canonical", "controller_profile")).to eq(replacement)
    expect(author(operation: :create_release, attributes: attributes, revisions: { "game:#{game.public_id}" => 0 }, key: "create-profile")).to eq(result)
  end

  it "leaves profiles, revisions and history unchanged on invalid, stale, conflicting and failed corrections" do
    attributes = { id: release.public_id, controller_profile: profile }
    revisions = { "game:#{game.public_id}" => 0, "release:#{release.public_id}" => 0 }
    author(attributes: attributes, revisions: revisions, key: "profile")
    state = CatalogAuthoringReadService.scope(game_id: game.public_id)
    expect { author(attributes: attributes, revisions: revisions) }.to raise_error(described_class::Conflict)
    expect { author(attributes: attributes.merge(controller_profile: nil), revisions: revisions, key: "profile") }.to raise_error(described_class::Conflict)
    expect { author(attributes: attributes.merge(controller_profile: {})) }.to raise_error(ActiveRecord::RecordInvalid)
    allow_any_instance_of(CatalogMutation).to receive(:update!).and_raise(ActiveRecord::StatementInvalid, "Synthetic failure")
    expect { author(attributes: attributes.merge(controller_profile: nil)) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(CatalogAuthoringReadService.scope(game_id: game.public_id)).to eq(state)
    expect(CatalogMutation.count).to eq(1)
  end

  it "revalidates system and edition corrections and accepts a replacement or explicit clearing" do
    release.update!(controller_profile: profile)
    expect { author(attributes: { id: release.public_id, system: "gb" }) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { author(attributes: { id: release.public_id, region: "Japan" }) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(CatalogMutation.count).to eq(0)
    expect(release.reload).to have_attributes(system: "snes", region: nil, controller_profile: profile)
    replacement = profile.merge("binding" => profile["binding"].merge("region" => "Japan"))
    author(attributes: { id: release.public_id, region: "Japan", controller_profile: replacement })
    expect(release.reload.controller_profile).to eq(replacement)
    author(attributes: { id: release.public_id, system: "gb", controller_profile: nil })
    expect(release.reload).to have_attributes(system: "gb", controller_profile: nil)
  end

  it "validates combined profile and media replacements in the complete preview without partial writes" do
    medium = release.release_media.sole
    attributes = { id: release.public_id, controller_profile: profile,
      media: [ { key: medium.key, position: 1, role: "game", sha1: medium.media_file.sha1, label: "Synthetic label" } ] }
    preview = described_class.preview(operation: :correct_release, attributes: attributes)
    expect { author(attributes: attributes, revisions: preview["expected_revisions"]) }.to raise_error(described_class::Conflict)
    author(attributes: attributes, revisions: preview["expected_revisions"], preview: preview)
    expect(release.reload.controller_profile).to eq(profile)
    expect(medium.reload.label).to eq("Synthetic label")
    invalid = attributes.merge(system: "nes", media: attributes[:media].map { |item| item.merge(label: "Rejected label") })
    expect { described_class.preview(operation: :correct_release, attributes: invalid) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(medium.reload.label).to eq("Synthetic label")
    expect(CatalogMutation.count).to eq(1)
  end

  it "preserves release-local profiles and evidence on reassignment and grouping" do
    release.update!(controller_profile: profile)
    target = create(:game)
    other_profile = profile.merge("prompts" => [])
    other = create(:release, game: target, system: "snes", controller_profile: other_profile)
    attributes = { id: release.public_id, game_id: target.public_id }
    preview = described_class.preview(operation: :reassign_release, attributes: attributes)
    author(operation: :reassign_release, attributes: attributes, revisions: preview["expected_revisions"], preview: preview)
    expect(release.reload).to have_attributes(game_id: target.id, controller_profile: profile)
    expect(other.reload.controller_profile).to eq(other_profile)
    attributes = { id: target.public_id, into_game_id: game.public_id }
    preview = described_class.preview(operation: :merge_games, attributes: attributes)
    author(operation: :merge_games, attributes: attributes, revisions: preview["expected_revisions"], preview: preview)
    expect(release.reload.controller_profile).to eq(profile)
    expect(other.reload.controller_profile).to eq(other_profile)
  end
end
