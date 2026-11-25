class CreateGamesAndReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :games do |t|
      t.string :public_id, null: false
      t.string :title, null: false
      t.timestamps
    end
    add_index :games, :public_id, unique: true

    create_table :releases do |t|
      t.references :game, null: false, foreign_key: true
      t.string :sha1, null: false
      t.string :system, null: false
      t.string :region
      t.string :revision
      t.timestamps
    end
    add_index :releases, :sha1, unique: true
  end
end
