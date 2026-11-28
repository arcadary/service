class CreateCompatibilityResults < ActiveRecord::Migration[8.1]
  def change
    create_table :compatibility_results do |t|
      t.references :release, null: false, foreign_key: true, index: false
      t.string :sha1, null: false
      t.string :device, null: false
      t.string :status, null: false
      t.string :core, null: false
      t.string :core_version, null: false
      t.string :startup_revision, null: false
      t.datetime :tested_at, null: false
      t.text :observed, null: false
      t.text :limits, null: false
      t.string :reason
      t.json :requires_input, null: false, default: []
      t.string :reviewer, null: false
      t.string :retry_key, null: false
      t.string :fingerprint, null: false
      t.datetime :created_at, null: false
    end
    add_index :compatibility_results, :retry_key, unique: true
    add_index :compatibility_results, [ :release_id, :device, :id ]
  end
end
