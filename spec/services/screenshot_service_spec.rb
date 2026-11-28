require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe ScreenshotService do
  include ScreenshotHelpers
  include ActiveJob::TestHelper

  let(:release) { create(:release, system: "gb") }
  let(:red) { png(pixel: "\xff\0\0\xff".b) }
  let(:green) { png(pixel: "\0\xff\0\xff".b) }

  it "stores the PNG under its content address, replaces the title with a new screenshot and purges the previous bytes" do
    previous = upload_screenshot(release: release, kind: "title")
    old_blob = previous.blob
    expect(old_blob.key).to eq("screenshots/#{previous.sha256}.png")
    perform_enqueued_jobs do
      screenshot = upload_screenshot(release: release, kind: "title", bytes: red)
      expect(screenshot.public_id).not_to eq(previous.public_id)
      expect(screenshot.blob.key).to eq("screenshots/#{screenshot.sha256}.png")
      expect(described_class.list(release_id: release.public_id)).to eq([ screenshot ])
    end
    expect(old_blob.service.exist?(old_blob.key)).to be(false)
    expect(ActiveStorage::Blob.exists?(old_blob.id)).to be(false)
  end

  it "lists the title first, appends gameplay in order and returns an image the release already has instead of a duplicate" do
    first = upload_screenshot(release: release)
    title = upload_screenshot(release: release, kind: "title", bytes: red)
    second = upload_screenshot(release: release, bytes: green)
    expect(described_class.list(release_id: release.public_id).map { |screenshot| [ screenshot, screenshot.position ] })
      .to eq([ [ title, 0 ], [ first, 1 ], [ second, 2 ] ])
    expect(upload_screenshot(release: release, kind: "title", bytes: green)).to eq(second)
    expect(upload_screenshot(release: release, bytes: red)).to eq(title)
    expect(described_class.list(release_id: release.public_id)).to eq([ title, first, second ])
    expect { described_class.list(release_id: "unknown") }.to raise_error(Release::ReleaseNotFound)
  end

  it "refuses a 51st gameplay screenshot, discards its bytes and leaves the upload confirmed" do
    (1..Screenshot::GAMEPLAY_LIMIT).each { |position| create(:screenshot, release: release, position: position) }
    upload = confirmed_screenshot
    expect { described_class.create(upload_id: upload.public_id, release_id: release.public_id, kind: "gameplay") }.to raise_error(Screenshot::LimitReached)
    expect(upload.reload.state).to eq("confirmed")
    expect(ActiveStorage::Blob.count).to eq(Screenshot::GAMEPLAY_LIMIT)
    expect(upload_screenshot(release: release, kind: "title").position).to eq(0)
  end

  it "keeps the screenshot and leaves the upload confirmed for a retry when the PNG exceeds the system or storage fails" do
    previous = upload_screenshot(release: release)
    attributes = previous.attributes
    oversized = confirmed_screenshot(bytes: png(width: 641))
    expect { described_class.create(upload_id: oversized.public_id, release_id: release.public_id, kind: "gameplay") }.to raise_error(Screenshot::InvalidImage)
    expect(oversized.reload.state).to eq("confirmed")
    upload = confirmed_screenshot(bytes: red)
    allow(ActiveStorage::Blob.services.fetch(:test_media)).to receive(:upload).and_raise(IOError)
    perform_enqueued_jobs do
      expect { described_class.create(upload_id: upload.public_id, release_id: release.public_id, kind: "gameplay") }.to raise_error(Screenshot::StorageUnavailable)
    end
    expect(upload.reload.state).to eq("confirmed")
    expect(previous.reload.attributes).to eq(attributes)
    expect(ActiveStorage::Blob.count).to eq(1)
  end

  it "removes by stable id, closes the gap and keeps identical pixels another release still shows" do
    first = upload_screenshot(release: release)
    second = upload_screenshot(release: release, bytes: red)
    third = upload_screenshot(release: release, bytes: green)
    shared = create(:release, game: release.game, system: "gb", sha1: release.sha1)
    other = upload_screenshot(release: shared, bytes: red)
    expect(other.blob).to eq(second.blob)
    perform_enqueued_jobs { expect(described_class.remove(screenshot_id: second.public_id)).to eq(second) }
    expect(described_class.list(release_id: release.public_id).map { |screenshot| [ screenshot, screenshot.position ] }).to eq([ [ first, 1 ], [ third, 2 ] ])
    expect(other.blob.service.exist?(other.blob.key)).to be(true)
    perform_enqueued_jobs { described_class.remove(screenshot_id: other.public_id) }
    expect(other.blob.service.exist?(other.blob.key)).to be(false)
    expect { described_class.remove(screenshot_id: other.public_id) }.to raise_error(Screenshot::NotFound)
  end

  it "selects the smallest stable release ID, prefers its first gameplay screenshot and ignores media order and equal first checksums" do
    first = create(:release, public_id: "a", system: "c64")
    second = create(:release, public_id: "z", game: first.game, sha1: first.sha1, system: "c64")
    expect(described_class.selected_for(game: first.game.reload)).to be_nil
    upload_screenshot(release: second)
    title = upload_screenshot(release: first, kind: "title")
    expect(described_class.selected_for(game: first.game.reload)).to eq(title)
    gameplay = upload_screenshot(release: first, bytes: red)
    later = upload_screenshot(release: first, bytes: green)
    expect(described_class.selected_for(game: first.game.reload)).to eq(gameplay)
    other = create(:release_medium, release: first)
    main = first.release_media.first
    first.update!(release_media_attributes: [
      { id: main.id, _destroy: true }, { id: other.id, _destroy: true },
      { key: "disk-2", position: 1, role: "game", media_file: other.media_file },
      { key: "main", position: 2, role: "game", media_file: main.media_file }
    ])
    expect(described_class.selected_for(game: first.game.reload)).to eq(gameplay)
    described_class.remove(screenshot_id: gameplay.public_id)
    expect(described_class.selected_for(game: first.game.reload)).to eq(later)
  end

  it "copies the game licence rather than granting rights at upload" do
    expect(upload_screenshot(release: release).licence).to eq("")
    release.game.update!(screenshot_licence: "CC-BY-4.0")
    expect(upload_screenshot(release: release, bytes: red).licence).to eq("CC-BY-4.0")
  end

  it "preserves release-scoped images and licences while regrouping and restoring screenshot selection on both games" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
    source = create(:game, screenshot_licence: "CC-BY-4.0")
    target = create(:game, screenshot_licence: "CC-BY-4.0")
    moving = create(:release, public_id: "a", game: source)
    staying = create(:release, public_id: "b", game: source)
    existing = create(:release, public_id: "z", game: target)
    moved = upload_screenshot(release: moving)
    stayed = upload_screenshot(release: staying)
    prior = upload_screenshot(release: existing)
    images = Screenshot.order(:id).map(&:attributes)
    bytes = moved.blob.download
    operations = [
      [ :reassign_release, { id: moving.public_id, game_id: target.public_id } ],
      [ :merge_games, { id: source.public_id, into_game_id: target.public_id } ],
      [ :restore_game, { id: source.public_id, canonical_game_id: target.public_id, release_ids: [ moving.public_id, staying.public_id ] } ]
    ]
    operations.each_with_index do |(operation, attributes), index|
      proposal = CatalogAuthoringService.preview(operation: operation, attributes: attributes)
      CatalogAuthoringService.call(operation: operation, attributes: attributes, preview: proposal,
        expected_revisions: proposal.fetch("expected_revisions"), reason: "Synthetic screenshot regrouping", idempotency_key: SecureRandom.uuid)
      expect(Screenshot.order(:id).map(&:attributes)).to eq(images)
      expect(moved.blob.download).to eq(bytes)
      expect(described_class.selected_for(game: source.reload)).to eq([ stayed, nil, moved ][index])
      expect(described_class.selected_for(game: target.reload)).to eq([ moved, moved, prior ][index])
    end
    expect(moved.reload).to have_attributes(release_id: moving.id, licence: "CC-BY-4.0")
  end
end
