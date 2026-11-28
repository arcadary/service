require "rails_helper"
require Rails.root.join("db/migrate/20261128180000_add_screenshot_sets")

RSpec.describe AddScreenshotSets do
  it "keeps one screenshot per release and image, preferring the title and its shared blob, refreshes that game's releases and gives every row a public id" do
    stub_const("ScreenshotSetsMigrationRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    ScreenshotSetsMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = ScreenshotSetsMigrationRecord.connection
    connection.create_table(:releases) { |table| table.integer :game_id; table.datetime :updated_at }
    connection.create_table(:screenshots) { |table| table.integer :release_id; table.integer :blob_id; table.string :kind; table.string :sha256 }
    connection.add_index :screenshots, [ :release_id, :kind ], unique: true
    connection.execute("INSERT INTO releases (id, game_id, updated_at) VALUES (1, 1, '2026-01-01'), (2, 1, '2026-01-01'), (3, 2, '2026-01-01')")
    connection.execute(<<~SQL)
      INSERT INTO screenshots (id, release_id, blob_id, kind, sha256) VALUES
      (1, 1, 7, 'gameplay', 'same'), (2, 1, 7, 'title', 'same'), (3, 2, 7, 'gameplay', 'same'), (4, 3, 8, 'gameplay', 'other'), (5, 3, 9, 'title', 'title')
    SQL
    migration = described_class.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.migrate(:up) }
    expect(connection.select_rows("SELECT id, blob_id FROM screenshots ORDER BY id")).to eq([ [ 2, 7 ], [ 3, 7 ], [ 4, 8 ], [ 5, 9 ] ])
    expect(connection.select_values("SELECT updated_at > '2026-01-01' FROM releases ORDER BY id")).to eq([ 1, 1, 0 ])
    public_ids = connection.select_values("SELECT public_id FROM screenshots")
    expect(public_ids).to all(match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/))
    expect(public_ids.uniq.size).to eq(4)
  ensure
    ScreenshotSetsMigrationRecord.connection_pool.disconnect!
  end
end
