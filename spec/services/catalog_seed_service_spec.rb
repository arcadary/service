require "rails_helper"
require_relative "../support/catalog_helpers"
require_relative "../support/screenshot_helpers"

RSpec.describe CatalogSeedService do
  include CatalogHelpers
  include ScreenshotHelpers

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
  end

  def author(operation:, attributes:)
    proposal = CatalogAuthoringService.preview(operation: operation, attributes: attributes)
    CatalogAuthoringService.call(operation: operation, attributes: attributes, preview: proposal,
      expected_revisions: proposal.fetch("expected_revisions"), reason: "Synthetic seed correction", idempotency_key: SecureRandom.uuid)
  end

  it "preserves grouped seed titles, licences, stable releases and screenshot evidence without modifying retired identities" do
    described_class.call
    source = Game.find_by!(public_id: "ucity")
    release = source.releases.sole
    screenshot = upload_screenshot(release: release)
    evidence = screenshot.attributes
    target = create(:game, title: "Reviewed target", screenshot_licence: source.screenshot_licence)
    author(operation: :merge_games, attributes: { id: source.public_id, into_game_id: target.public_id })
    before = snapshot
    audits = CatalogMutation.order(:id).map(&:attributes)
    result = described_class.call
    expect(snapshot).to eq(before)
    expect(CatalogMutation.order(:id).map(&:attributes)).to eq(audits)
    expect(screenshot.reload.attributes).to eq(evidence)
    expect(screenshot.release.reload.game).to eq(target)
    expect(result.find { |entry| entry[:seed] == "ucity" }.fetch(:divergences)).to include(
      type: "release", id: release.public_id, field: "game_id", source_value: "ucity", effective_value: target.public_id)
    expect(source.reload.retired_into_game_id).to eq(target.id)
  end

  it "keeps detached seed checksums unattached and matches secondary memberships without duplicating releases" do
    described_class.call
    release = Game.find_by!(public_id: "ucity").releases.sole
    original_sha1 = release.sha1
    file = create(:media_file)
    author(operation: :correct_release, attributes: { id: release.public_id, media: [ { key: "new", position: 1, role: "game", sha1: file.sha1 } ] })
    result = described_class.call
    expect(result.find { |entry| entry[:seed] == "ucity" }.fetch(:divergences)).to include(
      type: "media", id: original_sha1, field: "membership", source_value: "single release", effective_value: [])
    expect(Release.count).to eq(2)
    expect(MediaFile.find_by!(sha1: original_sha1).releases).to be_empty
    author(operation: :correct_release, attributes: { id: release.public_id, media: [
      { key: "new", position: 1, role: "game", sha1: file.sha1 }, { key: "original", position: 2, role: "game", sha1: original_sha1 }
    ] })
    before = snapshot
    described_class.call
    expect(snapshot).to eq(before)
    expect(Release.count).to eq(2)
  end
end
