# Catalog metadata for one emulator input, such as a cartridge or disk image,
# identified by SHA-1. Several releases can use the same file.
class MediaFile < ApplicationRecord
  has_many :release_media, dependent: :restrict_with_exception
  has_many :releases, through: :release_media

  validates :sha1, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{40}\z/ }
  validates :size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :format, format: { with: /\A[a-z0-9]+\z/ }, allow_nil: true
  validates :crc32, format: { with: /\A[0-9a-f]{8}\z/ }, allow_nil: true
  validates :md5, format: { with: /\A[0-9a-f]{32}\z/ }, allow_nil: true
  validate :sha1_is_stable, on: :update

  after_update :touch_releases

  private
    def touch_releases
      releases.touch_all
    end

    def sha1_is_stable
      errors.add(:sha1, "cannot change") if sha1_changed?
    end
end
