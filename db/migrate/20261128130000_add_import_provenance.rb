class AddImportProvenance < ActiveRecord::Migration[8.1]
  def change
    add_reference :releases, :source_game, foreign_key: { to_table: :games }
    add_column :media_files, :source_size, :bigint
    add_column :media_files, :source_format, :string
    add_column :media_files, :source_crc32, :string
    add_column :media_files, :source_md5, :string

    reversible do |direction|
      direction.up do
        execute "UPDATE releases SET source_game_id = game_id WHERE source_title IS NOT NULL"
        execute <<~SQL
          UPDATE releases SET source_game_id = COALESCE((
            SELECT games.id FROM catalog_mutations,
            json_each(catalog_mutations.record_changes) AS changes
            JOIN games ON games.public_id = json_extract(changes.value, '$.before.canonical.game_id')
            WHERE json_extract(changes.value, '$.before.type') = 'release'
            AND json_extract(changes.value, '$.before.id') = releases.public_id
            ORDER BY catalog_mutations.id LIMIT 1
          ), source_game_id) WHERE source_title IS NOT NULL
        SQL
        %w[size format crc32 md5].each do |field|
          execute "UPDATE media_files SET source_#{field} = #{field} WHERE NOT EXISTS (SELECT 1 FROM json_each(media_files.authored_fields) WHERE value = '#{field}')"
        end
        execute <<~SQL
          UPDATE games SET authored_fields = json_insert(authored_fields, '$[#]', 'grouping')
          WHERE public_id IN (
            SELECT json_extract(changes.value, '$.after.id')
            FROM catalog_mutations, json_each(catalog_mutations.record_changes) AS changes
            WHERE operation IN ('reassign_release', 'merge_games', 'restore_game')
            AND json_extract(changes.value, '$.after.type') = 'game'
          ) AND NOT EXISTS (SELECT 1 FROM json_each(games.authored_fields) WHERE value = 'grouping')
        SQL
      end
    end
  end
end
