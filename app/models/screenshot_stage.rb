class ScreenshotStage < ApplicationRecord
  class InvalidInput < StandardError; end
  class TargetMismatch < StandardError; end
  class Unavailable < StandardError; end
  class Consumed < StandardError; end

  belongs_to :blob, class_name: "ActiveStorage::Blob", optional: true

  attribute :public_id, :string, default: -> { SecureRandom.uuid }

  validates :public_id, :release_public_id, :expires_at, presence: true
  validates :public_id, uniqueness: true
  validates :source_sha1, format: { with: /\A[0-9a-f]{40}\z/ }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :kind, inclusion: { in: Screenshot::KINDS }
  validates :width, :height, numericality: { only_integer: true, greater_than: 0 }
end
