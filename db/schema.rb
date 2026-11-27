# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_26_210000) do
  create_table "game_identities", force: :cascade do |t|
    t.integer "game_id", null: false
    t.string "key", null: false
    t.index ["game_id"], name: "index_game_identities_on_game_id"
    t.index ["key"], name: "index_game_identities_on_key", unique: true
  end

  create_table "games", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "title", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "catalog_curated", default: false, null: false
    t.index ["public_id"], name: "index_games_on_public_id", unique: true
  end

  create_table "media_files", force: :cascade do |t|
    t.string "sha1", null: false
    t.bigint "size"
    t.string "format"
    t.string "crc32"
    t.string "md5"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sha1"], name: "index_media_files_on_sha1", unique: true
  end

  create_table "release_media", force: :cascade do |t|
    t.integer "release_id", null: false
    t.integer "media_file_id", null: false
    t.string "key", null: false
    t.integer "position", null: false
    t.string "label"
    t.string "role", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["media_file_id"], name: "index_release_media_on_media_file_id"
    t.index ["release_id", "key"], name: "index_release_media_on_release_id_and_key", unique: true
    t.index ["release_id", "position"], name: "index_release_media_on_release_id_and_position", unique: true
    t.index ["release_id"], name: "index_release_media_on_release_id"
  end

  create_table "releases", force: :cascade do |t|
    t.integer "game_id", null: false
    t.string "sha1", null: false
    t.string "system", null: false
    t.string "region"
    t.string "revision"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source_title"
    t.string "public_id", null: false
    t.json "startup"
    t.index ["game_id"], name: "index_releases_on_game_id"
    t.index ["public_id"], name: "index_releases_on_public_id", unique: true
    t.index ["sha1"], name: "index_releases_on_sha1"
  end

  add_foreign_key "game_identities", "games"
  add_foreign_key "release_media", "media_files"
  add_foreign_key "release_media", "releases"
  add_foreign_key "releases", "games"
end
