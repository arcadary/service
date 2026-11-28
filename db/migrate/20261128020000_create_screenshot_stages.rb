class CreateScreenshotStages < ActiveRecord::Migration[8.1]
  def change
    create_table :screenshot_stages do |t|
      t.string :public_id, null: false
      t.string :release_public_id, null: false
      t.string :source_sha1, null: false
      t.string :kind, null: false
      t.references :blob, foreign_key: { to_table: :active_storage_blobs }
      t.string :sha256, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :screenshot_stages, :public_id, unique: true
    add_index :screenshot_stages, :expires_at
  end
end
