class Upload < ApplicationRecord
  class InvalidInput < StandardError; end
  class NotFound < StandardError; end
  class Expired < StandardError; end
  class Conflict < StandardError; end
  class TooLarge < StandardError; end
  class Rejected < StandardError; end
  class Full < StandardError; end
  class InterruptedTransfer < StandardError; end
  class StorageDisabled < StandardError; end
  class StorageUnavailable < StandardError; end

  LIFETIME = 24.hours
  QUOTA_BYTES = 10.gigabytes
  STATES = %w[requested receiving checking confirmed rejected used].freeze
  RECEIVING = %w[requested receiving].freeze
  LIMITS = {
    "screenshot" => { file_bytes: 1.megabyte, upload_bytes: 1.megabyte, files: 1, content_types: %w[image/png] },
    "video" => { file_bytes: 8.megabytes, upload_bytes: 2.gigabytes, files: 4096,
                 content_types: %w[application/vnd.apple.mpegurl video/mp2t text/vtt] }
  }.freeze

  has_many :files, -> { order(:name) }, class_name: "UploadFile", dependent: :delete_all, inverse_of: :upload

  attribute :public_id, :string, default: -> { SecureRandom.uuid }

  validates :kind, inclusion: { in: LIMITS.keys }
  validates :state, inclusion: { in: STATES }
  attr_readonly :public_id, :kind, :expires_at

  def limits
    LIMITS.fetch(kind)
  end

  def expired?
    expires_at <= Time.current
  end
end
