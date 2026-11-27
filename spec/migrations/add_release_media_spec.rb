require "rails_helper"
require Rails.root.join("db/migrate/20261125203000_create_games_and_releases")
require Rails.root.join("db/migrate/20261126173000_add_catalog_identity")
require Rails.root.join("db/migrate/20261126210000_add_release_media")

RSpec.describe AddReleaseMedia do
  it "backfills every existing release without changing its checksum or timestamps" do
    stub_const("MigrationRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    MigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = MigrationRecord.connection
    [ CreateGamesAndReleases, AddCatalogIdentity ].each do |migration_class|
      migration = migration_class.new
      migration.define_singleton_method(:connection) { connection }
      migration.suppress_messages { migration.migrate(:up) }
    end
    connection.execute("INSERT INTO games (id, public_id, title, created_at, updated_at) VALUES (1, 'old-game', 'Old game', '2026-11-25', '2026-11-25')")
    [ "a" * 40, "b" * 40 ].each do |sha1|
      connection.execute("INSERT INTO releases (game_id, sha1, system, created_at, updated_at) VALUES (1, '#{sha1}', 'gb', '2026-11-25', '2026-11-25')")
    end
    migration = described_class.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.migrate(:up) }
    releases = connection.select_all("SELECT * FROM releases ORDER BY sha1").to_a
    expect(releases.map { |release| release.fetch("public_id") }.uniq.size).to eq(2)
    expect(releases.map { |release| release.fetch("public_id") }).to all(match(/\A[0-9a-f-]{36}\z/))
    expect(releases.map { |release| release.values_at("created_at", "updated_at", "startup") }).to eq([ [ "2026-11-25", "2026-11-25", nil ] ] * 2)
    media = connection.select_all("SELECT r.sha1 AS legacy_sha1, m.sha1, m.size, rm.key, rm.position, rm.role, rm.label FROM releases r JOIN release_media rm ON rm.release_id = r.id JOIN media_files m ON m.id = rm.media_file_id ORDER BY r.sha1").to_a
    expect(media).to eq([ "a" * 40, "b" * 40 ].map { |sha1| { "legacy_sha1" => sha1, "sha1" => sha1, "size" => nil, "key" => "main", "position" => 1, "role" => "game", "label" => nil } })
  ensure
    MigrationRecord.connection_pool.disconnect!
  end
end
