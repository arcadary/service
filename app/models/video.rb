class Video < ApplicationRecord
  class InvalidHls < StandardError; end
  class TargetMismatch < StandardError; end
  class NotFound < StandardError; end
  class StorageUnavailable < StandardError; end

  KINDS = %w[playthrough].freeze

  belongs_to :release, touch: true
  has_and_belongs_to_many :compatibility_results, join_table: :compatibility_result_videos

  validates :kind, inclusion: { in: KINDS }, uniqueness: { scope: :release_id }
  validates :source_sha1, format: { with: /\A[0-9a-f]{40}\z/ }
  attr_readonly :public_id, :release_id, :kind, :source_sha1, :capture, :verification, :files, :media
end
