class AddScreenshotSets < ActiveRecord::Migration[8.1]
  DUPLICATE = <<~SQL.squish
    EXISTS (SELECT 1 FROM screenshots kept WHERE kept.release_id = screenshots.release_id AND kept.sha256 = screenshots.sha256
    AND kept.id <> screenshots.id AND (kept.kind = 'title' OR screenshots.kind <> 'title' AND kept.id < screenshots.id))
  SQL

  def up
    execute <<~SQL.squish
      UPDATE releases SET updated_at = #{quote(Time.current)} WHERE game_id IN
      (SELECT releases.game_id FROM releases JOIN screenshots ON screenshots.release_id = releases.id WHERE #{DUPLICATE})
    SQL
    execute "DELETE FROM screenshots WHERE #{DUPLICATE}"
    add_column :screenshots, :public_id, :string
    select_values("SELECT id FROM screenshots").each do |id|
      execute "UPDATE screenshots SET public_id = #{quote(SecureRandom.uuid)} WHERE id = #{Integer(id)}"
    end
    change_column_null :screenshots, :public_id, false
    remove_index :screenshots, [ :release_id, :kind ]
    add_index :screenshots, :release_id, unique: true, where: "kind = 'title'", name: "index_screenshots_on_release_id_title"
    add_index :screenshots, [ :release_id, :sha256 ], unique: true
    add_index :screenshots, :public_id, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
