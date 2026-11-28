class AddScreenshotSets < ActiveRecord::Migration[8.1]
  def up
    add_column :screenshots, :public_id, :string
    add_column :screenshots, :position, :integer
    select_values("SELECT id FROM screenshots").each do |id|
      execute "UPDATE screenshots SET public_id = #{quote(SecureRandom.uuid)}, position = CASE kind WHEN 'title' THEN 0 ELSE 1 END WHERE id = #{Integer(id)}"
    end
    change_column_null :screenshots, :public_id, false
    change_column_null :screenshots, :position, false
    remove_index :screenshots, [ :release_id, :kind ]
    add_index :screenshots, :public_id, unique: true
    add_index :screenshots, [ :release_id, :position ], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
