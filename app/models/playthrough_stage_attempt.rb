class PlaythroughStageAttempt < ApplicationRecord
  belongs_to :playthrough_stage

  validates :kind, inclusion: { in: %w[transfer validation cleanup] }
  validates :state, inclusion: { in: %w[active finished fenced] }
  validates :token, :lease_expires_at, presence: true
  validates :generation, numericality: { only_integer: true, greater_than: 0 }
  validates :private_key, :service_name, :blob_identity, presence: true, if: -> { kind == "transfer" }
  attr_readonly :playthrough_stage_id, :kind, :token, :private_key, :service_name, :blob_identity
end
