class ReplacePlaythroughsWithVideos < ActiveRecord::Migration[8.1]
  def up
    drop_table :compatibility_result_playthroughs
    drop_table :playthroughs

    create_table :videos do |t|
      t.string :public_id, null: false
      t.references :release, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :source_sha1, null: false
      t.json :capture, null: false
      t.json :verification
      t.json :files, null: false
      t.json :media, null: false
      t.timestamps
    end
    add_index :videos, :public_id, unique: true
    add_index :videos, [ :release_id, :kind ], unique: true

    create_join_table :compatibility_results, :videos, table_name: :compatibility_result_videos do |t|
      t.index [ :compatibility_result_id, :video_id ], unique: true, name: "index_compatibility_result_videos_unique"
      t.index :video_id
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
