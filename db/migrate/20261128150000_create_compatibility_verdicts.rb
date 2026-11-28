class CreateCompatibilityVerdicts < ActiveRecord::Migration[8.1]
  def change
    create_table :compatibility_verdicts do |t|
      t.references :release, null: false, foreign_key: true
      t.string :device_class, null: false
      t.string :core, null: false
      t.string :core_version, null: false
      t.string :startup_revision, null: false
      t.string :state, null: false
      t.datetime :tested_at, null: false
      t.text :evidence
      t.text :limitations
      t.string :reviewer, null: false
      t.text :reason, null: false
      t.datetime :created_at, null: false
    end

    create_join_table :compatibility_verdicts, :playthroughs, table_name: :compatibility_verdict_playthroughs do |t|
      t.index [ :compatibility_verdict_id, :playthrough_id ], unique: true, name: "index_compatibility_verdict_playthroughs_unique"
      t.index :playthrough_id
    end
  end
end
