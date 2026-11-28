require "rails_helper"

RSpec.describe "Concurrent catalog authoring" do
  self.use_transactional_tests = false

  it "commits concurrent previewed merges once and replays after the identity scope changes" do
    source = create(:game)
    target = create(:game)
    release = create(:release, game: source)
    checksum = release.sha1
    key = SecureRandom.uuid
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
    attributes = { id: source.public_id, into_game_id: target.public_id }
    proposal = CatalogAuthoringService.preview(operation: :merge_games, attributes: attributes)
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          CatalogAuthoringService.call(operation: :merge_games, attributes: attributes, preview: proposal,
            expected_revisions: proposal.fetch("expected_revisions"), reason: "Concurrent synthetic merge", idempotency_key: key)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(results.first.fetch("records")).to eq(proposal.fetch("after"))
    expect(source.reload).to have_attributes(retired_into_game_id: target.id, authoring_revision: 1)
    expect(release.reload).to have_attributes(game_id: target.id, authoring_revision: 1)
    expect(CatalogMutation.where(idempotency_key: key).count).to eq(1)
  ensure
    threads&.each(&:join)
    CatalogMutation.where(idempotency_key: key).delete_all if key
    if release
      ReleaseMedium.where(release_id: release.id).delete_all
      release.delete
    end
    source&.delete
    target&.delete
    MediaFile.where(sha1: checksum).delete_all if checksum
  end

  it "commits concurrent retries once, including release media and the parent's revision" do
    game = create(:game)
    key = SecureRandom.uuid
    checksum = SecureRandom.hex(20)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Catalog Owner")
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          CatalogAuthoringService.call(operation: :create_release,
            attributes: { game_id: game.public_id, system: "gb", media: [ { key: "main", position: 1, role: "game", sha1: checksum } ] },
            expected_revisions: { "game:#{game.public_id}" => 0 }, reason: "Concurrent synthetic creation", idempotency_key: key)
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)
    expect(results.uniq.size).to eq(1)
    expect(game.reload.authoring_revision).to eq(1)
    expect(game.releases.count).to eq(1)
    expect(MediaFile.where(sha1: checksum).count).to eq(1)
    expect(CatalogMutation.where(idempotency_key: key).count).to eq(1)
  ensure
    threads&.each(&:join)
    CatalogMutation.where(idempotency_key: key).delete_all if key
    if game
      ReleaseMedium.where(release_id: game.releases.select(:id)).delete_all
      Release.where(game_id: game.id).delete_all
      game.destroy!
    end
    MediaFile.where(sha1: checksum).delete_all if checksum
  end
end
