class CreateValidationSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :validation_submissions do |t|
      t.string :sha1, null: false
      t.bigint :byte_size, null: false
      t.string :system, null: false
      t.datetime :completed_at
      t.timestamps
    end

    add_index :validation_submissions, :sha1, unique: true
    add_check_constraint :validation_submissions, "byte_size > 0 AND byte_size <= 134217728", name: "validation_submission_size"
  end
end
