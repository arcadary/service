class ReplaceStagingWithUploads < ActiveRecord::Migration[8.1]
  def up
    drop_table :playthrough_promotion_claims
    drop_table :playthrough_stage_attempts
    drop_table :playthrough_stage_objects
    drop_table :playthrough_stages
    drop_table :screenshot_stages

    create_table :uploads do |t|
      t.string :public_id, null: false
      t.string :kind, null: false
      t.string :state, null: false
      t.string :rejection_reason
      t.json :media
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :uploads, :public_id, unique: true
    add_index :uploads, :expires_at

    create_table :upload_files do |t|
      t.references :upload, null: false, foreign_key: true, index: false
      t.string :name, null: false
      t.bigint :byte_size, null: false
      t.string :sha256, null: false
      t.string :content_type, null: false
      t.timestamps
    end
    add_index :upload_files, [ :upload_id, :name ], unique: true

    create_table :playthroughs do |t|
      t.string :public_id, null: false
      t.references :release, null: false, foreign_key: true
      t.string :source_sha1, null: false
      t.json :capture, null: false
      t.json :verification
      t.json :files, null: false
      t.json :media, null: false
      t.timestamps
    end
    add_index :playthroughs, :public_id, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
