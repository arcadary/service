class PlaythroughStageObject < ApplicationRecord
  belongs_to :playthrough_stage
  belongs_to :blob, class_name: "ActiveStorage::Blob", optional: true

  attribute :public_id, :string, default: -> { SecureRandom.uuid }
  attr_readonly :public_id, :playthrough_stage_id

  validates :public_id, presence: true
  validates :path, :content_type, presence: true, unless: :pruned_at?
  validates :public_id, uniqueness: true
  validates :path, uniqueness: { scope: :playthrough_stage_id }, unless: :pruned_at?
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 8.megabytes }, unless: :pruned_at?
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }, unless: :pruned_at?
  validates :received_at, presence: true, if: :blob_id?
  validates :blob_id, presence: true, if: :received_at?
  validates :path, :byte_size, :sha256, :content_type, :blob_id, :received_at, absence: true, if: :pruned_at?
  validate :metadata_is_immutable

  private

  def metadata_is_immutable
    return unless persisted? && !pruned_at?
    return unless %w[path byte_size sha256 content_type].any? { |name| will_save_change_to_attribute?(name) }

    errors.add(:base, :invalid)
  end
end
