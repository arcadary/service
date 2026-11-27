class CreateScreenshots < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :screenshot_licence, :string, null: false, default: ""

    create_table :screenshots do |t|
      t.references :release, null: false, foreign_key: true
      t.references :blob, null: false, foreign_key: { to_table: :active_storage_blobs }
      t.string :kind, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.string :sha256, null: false
      t.string :licence, null: false, default: ""
      t.timestamps
    end
    add_index :screenshots, [ :release_id, :kind ], unique: true
    add_index :screenshots, :sha256
  end
end
