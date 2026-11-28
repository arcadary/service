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
        %w[size format crc32 md5].each do |field|
          execute "UPDATE media_files SET source_#{field} = #{field} WHERE NOT EXISTS (SELECT 1 FROM json_each(media_files.authored_fields) WHERE value = '#{field}')"
        end
      end
    end
  end
end
