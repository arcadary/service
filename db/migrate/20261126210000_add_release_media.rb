class AddReleaseMedia < ActiveRecord::Migration[8.1]
  def up
    add_column :releases, :public_id, :string
    add_column :releases, :startup, :json
    remove_index :releases, :sha1
    add_index :releases, :sha1

    create_table :media_files do |t|
      t.string :sha1, null: false
      t.bigint :size
      t.string :format
      t.string :crc32
      t.string :md5
      t.timestamps
      t.index :sha1, unique: true
    end

    create_table :release_media do |t|
      t.references :release, null: false, foreign_key: true
      t.references :media_file, null: false, foreign_key: true
      t.string :key, null: false
      t.integer :position, null: false
      t.string :label
      t.string :role, null: false
      t.timestamps
      t.index [ :release_id, :key ], unique: true
      t.index [ :release_id, :position ], unique: true
    end

    select_all("SELECT id, sha1, created_at, updated_at FROM releases").each do |release|
      public_id = connection.quote(SecureRandom.uuid)
      execute("UPDATE releases SET public_id = #{public_id} WHERE id = #{release['id']}")
      sha1 = connection.quote(release.fetch("sha1"))
      created_at = connection.quote(release.fetch("created_at"))
      updated_at = connection.quote(release.fetch("updated_at"))
      execute("INSERT INTO media_files (sha1, created_at, updated_at) VALUES (#{sha1}, #{created_at}, #{updated_at})")
      execute(<<~SQL)
        INSERT INTO release_media (release_id, media_file_id, key, position, role, created_at, updated_at)
        SELECT #{release['id']}, id, 'main', 1, 'game', #{created_at}, #{updated_at} FROM media_files WHERE sha1 = #{sha1}
      SQL
    end
    change_column_null :releases, :public_id, false
    add_index :releases, :public_id, unique: true
  end

  def down
    drop_table :release_media
    drop_table :media_files
    remove_column :releases, :startup
    remove_column :releases, :public_id
    remove_index :releases, :sha1
    add_index :releases, :sha1, unique: true
  end
end
