class Screenshot < ApplicationRecord
  class InvalidImage < StandardError; end
  class InvalidKind < StandardError; end
  class NotFound < StandardError; end
  class StorageUnavailable < StandardError; end

  KINDS = %w[title gameplay].freeze

  belongs_to :release, touch: true
  belongs_to :blob, class_name: "ActiveStorage::Blob"

  validates :kind, inclusion: { in: KINDS }, uniqueness: { scope: :release_id }
  validates :width, :height, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :licence, exclusion: { in: [ nil ] }
end
