class AddPlaythroughPromotionClaims < ActiveRecord::Migration[8.1]
  def change
    add_column :playthrough_stages, :promotion_state, :string

    create_table :playthrough_promotion_claims do |t|
      t.references :playthrough_stage, null: false, foreign_key: true
      t.string :token, null: false
      t.string :validation_sha256, null: false
      t.string :state, null: false, default: "active"
      t.timestamps
    end
    add_index :playthrough_promotion_claims, :token, unique: true
    add_index :playthrough_promotion_claims, :playthrough_stage_id, unique: true,
      where: "state = 'active'", name: "index_playthrough_promotion_claims_active_stage"
  end
end
