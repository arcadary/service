class AddCatalogIdentity < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :catalog_curated, :boolean, default: false, null: false
    add_column :releases, :source_title, :string
    create_table :game_identities do |t|
      t.references :game, null: false, foreign_key: true
      t.string :key, null: false
      t.index :key, unique: true
    end
  end
end
