class ValidationSubmission < ApplicationRecord
  class InvalidMetadata < StandardError; end
  class InvalidAdmission < StandardError; end
  class SubmissionConflict < StandardError; end
  class KnownRelease < StandardError; end
  class FileTooLarge < StandardError; end
  class SizeMismatch < StandardError; end
  class ChecksumMismatch < StandardError; end
  class UploadTimeout < StandardError; end
  class Unavailable < StandardError; end

  MAX_BYTES = 134_217_728

  validates :sha1, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{40}\z/ }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_BYTES }
  validates :system, inclusion: { in: Release::SYSTEMS }
  validate :facts_are_immutable, on: :update

  private
    def facts_are_immutable
      errors.add(:base, "submission facts cannot change") if %w[sha1 byte_size system].any? { |field| will_save_change_to_attribute?(field) }
    end
end
