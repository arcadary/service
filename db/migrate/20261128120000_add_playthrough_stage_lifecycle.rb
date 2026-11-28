class AddPlaythroughStageLifecycle < ActiveRecord::Migration[8.1]
  def change
    add_column :playthrough_stages, :declared_at, :datetime
    reversible do |direction|
      direction.up { execute "UPDATE playthrough_stages SET declared_at = created_at" }
    end
    change_column_null :playthrough_stages, :declared_at, false
    add_column :playthrough_stages, :expired_at, :datetime
    add_column :playthrough_stages, :reclaimed_at, :datetime
    add_column :playthrough_stages, :cleanup_visits, :integer, null: false, default: 0
    add_index :playthrough_stages, [ :cleanup_visits, :id ]
    add_column :playthrough_stage_objects, :pruned_at, :datetime
    change_column_null :playthrough_stage_objects, :path, true
    change_column_null :playthrough_stage_objects, :byte_size, true
    change_column_null :playthrough_stage_objects, :sha256, true
    change_column_null :playthrough_stage_objects, :content_type, true

    create_table :playthrough_stage_attempts do |t|
      t.references :playthrough_stage, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :token, null: false
      t.integer :generation, null: false, default: 1
      t.string :state, null: false, default: "active"
      t.datetime :lease_expires_at, null: false
      t.bigint :blob_identity
      t.string :private_key
      t.string :service_name
      t.boolean :cleanup_pending, null: false, default: false
      t.datetime :absence_checked_at
      t.integer :cleanup_visits, null: false, default: 0
      t.timestamps
    end
    add_index :playthrough_stage_attempts, :private_key, unique: true
    add_index :playthrough_stage_attempts, [ :playthrough_stage_id, :kind, :state ], name: "index_playthrough_attempt_owners"
  end
end
