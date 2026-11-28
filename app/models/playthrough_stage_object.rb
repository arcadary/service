class PlaythroughStageObject < ApplicationRecord
  belongs_to :playthrough_stage
  belongs_to :blob, class_name: "ActiveStorage::Blob", optional: true

  attribute :public_id, :string, default: -> { SecureRandom.uuid }
  attr_readonly :public_id, :playthrough_stage_id, :path, :byte_size, :sha256, :content_type

  validates :public_id, :path, :content_type, presence: true
  validates :public_id, uniqueness: true
  validates :path, uniqueness: { scope: :playthrough_stage_id }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 8.megabytes }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
end
