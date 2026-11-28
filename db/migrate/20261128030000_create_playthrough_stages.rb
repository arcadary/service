class CreatePlaythroughStages < ActiveRecord::Migration[8.1]
  def change
    create_table :playthrough_stages do |t|
      t.string :public_id, null: false
      t.references :release, null: false, foreign_key: true
      t.string :retry_key, null: false
      t.string :declaration_sha256, null: false
      t.string :package_sha256, null: false
      t.json :declaration, null: false
      t.timestamps
    end
    add_index :playthrough_stages, :public_id, unique: true
    add_index :playthrough_stages, :retry_key, unique: true

    create_table :playthrough_stage_objects do |t|
      t.references :playthrough_stage, null: false, foreign_key: true
      t.string :public_id, null: false
      t.string :path, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.string :content_type, null: false
      t.references :blob, foreign_key: { to_table: :active_storage_blobs }
      t.datetime :received_at
      t.timestamps
    end
    add_index :playthrough_stage_objects, :public_id, unique: true
    add_index :playthrough_stage_objects, [ :playthrough_stage_id, :path ], unique: true
  end
end
