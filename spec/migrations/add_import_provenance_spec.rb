require "rails_helper"
require Rails.root.join("db/migrate/20261128130000_add_import_provenance")

RSpec.describe AddImportProvenance do
  it "recovers pre-grouping source ownership and protects existing grouping titles without inventing corrected source metadata" do
    stub_const("ProvenanceMigrationRecord", Class.new(ActiveRecord::Base) { self.abstract_class = true })
    ProvenanceMigrationRecord.establish_connection(adapter: "sqlite3", database: ":memory:")
    connection = ProvenanceMigrationRecord.connection
    connection.create_table(:games) { |table| table.string :public_id; table.json :authored_fields, default: [] }
    connection.create_table(:releases) { |table| table.integer :game_id; table.string :public_id; table.string :source_title }
    connection.create_table(:media_files) { |table| table.integer :size; table.string :format; table.string :crc32; table.string :md5; table.json :authored_fields, default: [] }
    connection.create_table(:catalog_mutations) { |table| table.string :operation; table.json :record_changes }
    connection.execute("INSERT INTO games (id, public_id, authored_fields) VALUES (1, 'source', '[]'), (2, 'target', '[\"title_aliases\"]')")
    connection.execute("INSERT INTO releases (game_id, public_id, source_title) VALUES (2, 'release', 'Original (USA)')")
    connection.execute("INSERT INTO media_files (size, format, authored_fields) VALUES (20, 'nes', '[\"size\"]')")
    changes = [ { before: { type: "release", id: "release", canonical: { game_id: "source" } }, after: { type: "release", id: "release" } },
      { after: { type: "game", id: "source" } }, { after: { type: "game", id: "target" } } ]
    connection.execute("INSERT INTO catalog_mutations (operation, record_changes) VALUES ('merge_games', #{connection.quote(JSON.generate(changes))})")
    migration = described_class.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages { migration.migrate(:up) }
    expect(connection.select_value("SELECT source_game_id FROM releases")).to eq(1)
    expect(connection.select_values("SELECT authored_fields FROM games ORDER BY id").map { |fields| JSON.parse(fields) }).to eq([ [ "grouping" ], %w[title_aliases grouping] ])
    expect(connection.select_one("SELECT size, source_size, source_format FROM media_files")).to eq("size" => 20, "source_size" => nil, "source_format" => "nes")
    expect(connection.select_value("SELECT COUNT(*) FROM catalog_mutations")).to eq(1)
  ensure
    ProvenanceMigrationRecord.connection_pool.disconnect!
  end
end
