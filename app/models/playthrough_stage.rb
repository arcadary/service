class PlaythroughStage < ApplicationRecord
  class InvalidDeclaration < StandardError; end
  class TooLarge < StandardError; end
  class TargetMismatch < StandardError; end
  class Conflict < StandardError; end
  class NotFound < StandardError; end
  class InterruptedTransfer < StandardError; end
  class StorageUnavailable < StandardError; end
  class UploadNotAuthorized < StandardError; end
  class StageIncomplete < StandardError; end
  class InvalidHls < StandardError; end
  class PackageIntegrityMismatch < StandardError; end
  class Expired < StandardError; end

  belongs_to :release
  has_many :objects, -> { order(:path) }, class_name: "PlaythroughStageObject", dependent: :restrict_with_exception
  has_many :attempts, class_name: "PlaythroughStageAttempt", dependent: :restrict_with_exception
  has_many :promotion_claims, class_name: "PlaythroughPromotionClaim", dependent: :restrict_with_exception

  attribute :public_id, :string, default: -> { SecureRandom.uuid }
  attr_readonly :public_id, :release_id, :retry_key, :declaration_sha256, :package_sha256, :declared_at

  validates :public_id, :retry_key, :declaration, presence: true
  validates :declared_at, presence: true
  validates :public_id, :retry_key, uniqueness: true
  validates :package_sha256, :declaration_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :validation_state, inclusion: { in: %w[validated validation_failed] }, allow_nil: true
  validates :promotion_state, inclusion: { in: %w[promoting published] }, allow_nil: true
  validates :validation_error, inclusion: { in: %w[invalid_hls package_integrity_mismatch] }, allow_nil: true
  validates :validation_result, presence: true, if: -> { validation_state == "validated" }
  validates :validation_error, presence: true, if: -> { validation_state == "validation_failed" }
  validate :declaration_is_immutable
  validate :terminal_times_are_ordered

  private

  def declaration_is_immutable
    return unless persisted? && declaration_changed?
    return if reclaimed_at && declaration == declaration_in_database.except("manifest")

    errors.add(:declaration, :invalid)
  end

  def terminal_times_are_ordered
    errors.add(:expired_at, :invalid) if expired_at && expired_at != declared_at + 24.hours
    errors.add(:reclaimed_at, :invalid) if reclaimed_at && (!expired_at || reclaimed_at < expired_at)
  end
end
