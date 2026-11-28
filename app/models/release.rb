# A specific edition of a game for one system. Ordered ReleaseMedium rows attach
# its MediaFile records. A multi-disk run depends on the relevant disks, their
# order, and the release's startup configuration.
class Release < ApplicationRecord
  class InvalidSha1 < StandardError; end
  class ReleaseNotFound < StandardError; end
  class AmbiguousRelease < StandardError; end

  SYSTEMS = %w[nes snes gb gbc megadrive pcengine atari2600 c64].freeze

  belongs_to :game, touch: true
  has_many :release_media, -> { order(:position) }, dependent: :destroy, inverse_of: :release
  has_many :media_files, through: :release_media
  has_many :screenshots, dependent: :restrict_with_exception
  accepts_nested_attributes_for :release_media, allow_destroy: true

  attribute :public_id, :string, default: -> { SecureRandom.uuid }
  before_validation :build_main_medium, on: :create
  before_validation :set_first_checksum

  validates :sha1, presence: true,
    format: { with: /\A[0-9a-f]{40}\z/ }
  validates :public_id, presence: true, uniqueness: true
  validates :system, inclusion: { in: SYSTEMS }
  validate :public_id_is_stable, on: :update
  validate :startup_and_media
  validate :controller_profile_matches_release
  after_touch -> { ReleaseService.synchronize_checksum(release_id: id) }

  private
    def controller_profile_matches_release
      ReleaseControllerProfileService.errors(release: self).each { |error| errors.add(:controller_profile, error) }
    end

    def build_main_medium
      return if release_media.any? || !/\A[0-9a-f]{40}\z/.match?(sha1.to_s)

      release_media.build(key: "main", position: 1, role: "game", media_file: MediaFile.find_or_initialize_by(sha1: sha1))
    end

    def set_first_checksum
      first = release_media.reject(&:marked_for_destruction?).min_by { |medium| medium.position || 0 }
      self.sha1 = first.media_file.sha1 if first&.media_file
    end

    def public_id_is_stable
      errors.add(:public_id, "cannot change") if public_id_changed?
    end

    def startup_and_media
      ReleaseStartupService.errors(release: self, media: release_media.reject(&:marked_for_destruction?)).each do |error|
        errors.add(:startup, error)
      end
    end
end
