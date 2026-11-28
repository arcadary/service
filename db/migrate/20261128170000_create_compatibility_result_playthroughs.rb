class CreateCompatibilityResultPlaythroughs < ActiveRecord::Migration[8.1]
  def change
    create_join_table :compatibility_results, :playthroughs, table_name: :compatibility_result_playthroughs do |t|
      t.index [ :compatibility_result_id, :playthrough_id ], unique: true, name: "index_compatibility_result_playthroughs_unique"
      t.index :playthrough_id
    end
  end
end
