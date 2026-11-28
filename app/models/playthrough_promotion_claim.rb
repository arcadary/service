class PlaythroughPromotionClaim < ApplicationRecord
  belongs_to :playthrough_stage

  attr_readonly :playthrough_stage_id, :token, :validation_sha256
  self.filter_attributes += [ :token, :validation_sha256 ]

  validates :token, format: { with: /\A[0-9a-f]{96}\z/ }, uniqueness: true
  validates :validation_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :state, inclusion: { in: %w[active completed released] }
end
