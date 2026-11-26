class ReleaseMedium < ApplicationRecord
  belongs_to :release, touch: true, inverse_of: :release_media
  belongs_to :media_file, autosave: true

  validates :key, format: { with: /\A[a-z0-9-]{1,32}\z/ }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :label, length: { maximum: 80 }, allow_nil: true
  validates :role, inclusion: { in: %w[game save] }
  validate :release_configuration
  validate :key_is_stable, on: :update

  before_destroy :preserve_release_configuration

  private
    def key_is_stable
      errors.add(:key, "cannot change") if key_changed?
    end

    def preserve_release_configuration
      return if destroyed_by_association

      media = release.release_media.reject { |medium| medium == self || medium.marked_for_destruction? }
      ReleaseStartupService.errors(release: release, media: media).each { |error| errors.add(:base, error) }
      throw :abort if errors.any?
    end

    def release_configuration
      return unless release

      media = release.release_media.to_a.reject { |medium| medium.marked_for_destruction? || (medium.id && medium.id == id) || medium.equal?(self) }
      media << self unless marked_for_destruction?
      ReleaseStartupService.errors(release: release, media: media).each { |error| errors.add(:base, error) }
    end
end
