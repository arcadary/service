require "rails_helper"
require Rails.root.join("db/migrate/20261128180000_add_screenshot_sets")

RSpec.describe AddScreenshotSets do
  it "keeps existing screenshots, giving each a public id and the title position 0 before its one gameplay screenshot" do
    stub_const("ScreenshotSetsMigrationRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    ScreenshotSetsMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = ScreenshotSetsMigrationRecord.connection
    connection.create_table(:screenshots) { |table| table.integer :release_id; table.string :kind }
    connection.add_index :screenshots, [ :release_id, :kind ], unique: true
    connection.execute("INSERT INTO screenshots (release_id, kind) VALUES (1, 'gameplay'), (1, 'title'), (2, 'gameplay')")
    migration = described_class.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.migrate(:up) }
    rows = connection.select_rows("SELECT release_id, kind, position, public_id FROM screenshots ORDER BY id")
    expect(rows.map { |row| row.first(3) }).to eq([ [ 1, "gameplay", 1 ], [ 1, "title", 0 ], [ 2, "gameplay", 1 ] ])
    expect(rows.map(&:last)).to all(match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/))
    expect(rows.map(&:last).uniq.size).to eq(3)
  ensure
    ScreenshotSetsMigrationRecord.connection_pool.disconnect!
  end
end
