require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe ScreenshotService do
  include ScreenshotHelpers
  include ActiveJob::TestHelper

  let(:release) { create(:release, system: "gb") }

  it "replaces one kind atomically and purges its previous bytes" do
    previous = upload_screenshot(release: release)
    old_blob = previous.blob
    old_hash = previous.sha256
    perform_enqueued_jobs do
      screenshot = upload_screenshot(release: release, bytes: png(pixel: "\xff\0\0\xff".b))
      expect(screenshot.id).to eq(previous.id)
      expect(screenshot.sha256).not_to eq(old_hash)
      expect(Screenshot.where(release: release, kind: "gameplay").count).to eq(1)
      expect { described_class.find_by(sha256: old_hash) }.to raise_error(Screenshot::NotFound)
    end
    expect(old_blob.service.exist?(old_blob.key)).to be(false)
  end

  it "preserves the record, bytes and references on validation and storage failure" do
    previous = upload_screenshot(release: release)
    attributes = previous.attributes
    bytes = previous.blob.download
    expect { upload_screenshot(release: release, bytes: "broken") }.to raise_error(Screenshot::InvalidImage)
    allow(ActiveStorage::Blob.service).to receive(:upload).and_raise(IOError)
    perform_enqueued_jobs do
      expect { upload_screenshot(release: release, bytes: png(pixel: "\xff\0\0\xff".b)) }.to raise_error(Screenshot::StorageUnavailable)
    end
    expect(previous.reload.attributes).to eq(attributes)
    expect(previous.blob.download).to eq(bytes)
    expect(described_class.find_by(sha256: previous.sha256)).to eq(bytes)
    expect(ActiveStorage::Blob.count).to eq(1)
  end

  it "removes by stable public ID and preserves identical bytes referenced by another release" do
    first = upload_screenshot(release: release)
    shared = create(:release, game: release.game, system: "gb", sha1: release.sha1)
    second = upload_screenshot(release: shared)
    expect(first.sha256).to eq(second.sha256)
    perform_enqueued_jobs do
      described_class.remove(public_id: release.public_id, kind: "gameplay")
    end
    expect(first.blob.service.exist?(first.blob.key)).to be(false)
    expect(described_class.find_by(sha256: second.sha256)).to eq(second.blob.download)
    perform_enqueued_jobs do
      described_class.remove(public_id: shared.public_id, kind: "gameplay")
    end
    expect(second.blob.service.exist?(second.blob.key)).to be(false)
    expect { described_class.find_by(sha256: second.sha256) }.to raise_error(Screenshot::NotFound)
  end

  it "selects the smallest stable release ID, prefers gameplay there and ignores media order and equal first checksums" do
    first = create(:release, public_id: "a", system: "c64")
    second = create(:release, public_id: "z", game: first.game, sha1: first.sha1, system: "c64")
    expect(described_class.selected_for(game: first.game.reload)).to be_nil
    upload_screenshot(release: second)
    title = upload_screenshot(release: first, kind: "title")
    expect(described_class.selected_for(game: first.game.reload)).to eq(title)
    gameplay = upload_screenshot(release: first)
    expect(described_class.selected_for(game: first.game.reload)).to eq(gameplay)
    other = create(:release_medium, release: first)
    main = first.release_media.first
    first.update!(release_media_attributes: [
      { id: main.id, _destroy: true }, { id: other.id, _destroy: true },
      { key: "disk-2", position: 1, role: "game", media_file: other.media_file },
      { key: "main", position: 2, role: "game", media_file: main.media_file }
    ])
    expect(described_class.selected_for(game: first.game.reload)).to eq(gameplay)
  end

  it "copies the game licence rather than granting rights at upload" do
    expect(upload_screenshot(release: release).licence).to eq("")
    release.game.update!(screenshot_licence: "CC-BY-4.0")
    expect(upload_screenshot(release: release).licence).to eq("CC-BY-4.0")
  end
end
