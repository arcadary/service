class AddCatalogAuthoring < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :authoring_revision, :integer, default: 0, null: false
    add_column :games, :authored_fields, :json, default: [], null: false
    add_column :games, :title_aliases, :json, default: [], null: false
    add_column :games, :source_title, :string
    add_column :releases, :authoring_revision, :integer, default: 0, null: false
    add_column :releases, :authored_fields, :json, default: [], null: false
    add_column :releases, :source_system, :string
    add_column :releases, :source_region, :string
    add_column :releases, :source_revision, :string
    add_column :media_files, :authoring_revision, :integer, default: 0, null: false
    add_column :media_files, :authored_fields, :json, default: [], null: false

    reversible do |direction|
      direction.up do
        execute "UPDATE games SET source_title = title"
        execute "UPDATE releases SET source_system = system, source_region = region, source_revision = revision"
      end
    end

    create_table :catalog_mutations do |t|
      t.string :idempotency_key, null: false
      t.string :fingerprint, null: false
      t.string :operation, null: false
      t.string :admin_name, null: false
      t.text :reason, null: false
      t.json :record_changes, null: false, default: []
      t.json :result, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :catalog_mutations, :idempotency_key, unique: true
  end
end
