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

ActiveRecord::Schema[8.1].define(version: 2026_11_28_160000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "catalog_mutations", force: :cascade do |t|
    t.string "idempotency_key", null: false
    t.string "fingerprint", null: false
    t.string "operation", null: false
    t.string "admin_name", null: false
    t.text "reason", null: false
    t.json "record_changes", default: [], null: false
    t.json "result", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["idempotency_key"], name: "index_catalog_mutations_on_idempotency_key", unique: true
  end

  create_table "compatibility_results", force: :cascade do |t|
    t.integer "release_id", null: false
    t.string "sha1", null: false
    t.string "device", null: false
    t.string "status", null: false
    t.string "core", null: false
    t.string "core_version", null: false
    t.string "startup_revision", null: false
    t.datetime "tested_at", null: false
    t.text "observed", null: false
    t.text "limits", null: false
    t.string "reason"
    t.json "requires_input", default: [], null: false
    t.string "reviewer", null: false
    t.string "retry_key", null: false
    t.string "fingerprint", null: false
    t.datetime "created_at", null: false
    t.index ["release_id", "device", "id"], name: "index_compatibility_results_on_release_id_and_device_and_id"
    t.index ["retry_key"], name: "index_compatibility_results_on_retry_key", unique: true
  end

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
    t.string "screenshot_licence", default: "", null: false
    t.integer "authoring_revision", default: 0, null: false
    t.json "authored_fields", default: [], null: false
    t.json "title_aliases", default: [], null: false
    t.string "source_title"
    t.integer "retired_into_game_id"
    t.index ["public_id"], name: "index_games_on_public_id", unique: true
    t.index ["retired_into_game_id"], name: "index_games_on_retired_into_game_id"
  end

  create_table "media_files", force: :cascade do |t|
    t.string "sha1", null: false
    t.bigint "size"
    t.string "format"
    t.string "crc32"
    t.string "md5"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "authoring_revision", default: 0, null: false
    t.json "authored_fields", default: [], null: false
    t.bigint "source_size"
    t.string "source_format"
    t.string "source_crc32"
    t.string "source_md5"
    t.index ["sha1"], name: "index_media_files_on_sha1", unique: true
  end

  create_table "playthroughs", force: :cascade do |t|
    t.string "public_id", null: false
    t.integer "release_id", null: false
    t.string "source_sha1", null: false
    t.json "capture", null: false
    t.json "verification"
    t.json "files", null: false
    t.json "media", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["public_id"], name: "index_playthroughs_on_public_id", unique: true
    t.index ["release_id"], name: "index_playthroughs_on_release_id"
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
    t.integer "authoring_revision", default: 0, null: false
    t.json "authored_fields", default: [], null: false
    t.string "source_system"
    t.string "source_region"
    t.string "source_revision"
    t.json "controller_profile"
    t.integer "source_game_id"
    t.index ["game_id"], name: "index_releases_on_game_id"
    t.index ["public_id"], name: "index_releases_on_public_id", unique: true
    t.index ["sha1"], name: "index_releases_on_sha1"
    t.index ["source_game_id"], name: "index_releases_on_source_game_id"
  end

  create_table "screenshots", force: :cascade do |t|
    t.integer "release_id", null: false
    t.integer "blob_id", null: false
    t.string "kind", null: false
    t.integer "width", null: false
    t.integer "height", null: false
    t.string "sha256", null: false
    t.string "licence", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["blob_id"], name: "index_screenshots_on_blob_id"
    t.index ["release_id", "kind"], name: "index_screenshots_on_release_id_and_kind", unique: true
    t.index ["release_id"], name: "index_screenshots_on_release_id"
    t.index ["sha256"], name: "index_screenshots_on_sha256"
  end

  create_table "upload_files", force: :cascade do |t|
    t.integer "upload_id", null: false
    t.string "name", null: false
    t.bigint "byte_size", null: false
    t.string "sha256", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["upload_id", "name"], name: "index_upload_files_on_upload_id_and_name", unique: true
  end

  create_table "uploads", force: :cascade do |t|
    t.string "public_id", null: false
    t.string "kind", null: false
    t.string "state", null: false
    t.string "rejection_reason"
    t.json "media"
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_uploads_on_expires_at"
    t.index ["public_id"], name: "index_uploads_on_public_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "compatibility_results", "releases"
  add_foreign_key "game_identities", "games"
  add_foreign_key "games", "games", column: "retired_into_game_id"
  add_foreign_key "playthroughs", "releases"
  add_foreign_key "release_media", "media_files"
  add_foreign_key "release_media", "releases"
  add_foreign_key "releases", "games"
  add_foreign_key "releases", "games", column: "source_game_id"
  add_foreign_key "screenshots", "active_storage_blobs", column: "blob_id"
  add_foreign_key "screenshots", "releases"
  add_foreign_key "upload_files", "uploads"
end
