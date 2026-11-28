class Playthrough < ApplicationRecord
  class InvalidHls < StandardError; end
  class TargetMismatch < StandardError; end

  belongs_to :release

  validates :source_sha1, format: { with: /\A[0-9a-f]{40}\z/ }
  attr_readonly :public_id, :release_id, :source_sha1, :capture, :verification, :files, :media

  def self.storage_prefix(public_id:)
    "playthroughs/#{public_id}"
  end
end
