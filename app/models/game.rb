class Game < ApplicationRecord
  attr_accessor :selected_screenshot

  has_many :releases, dependent: :restrict_with_exception
  has_many :game_identities, dependent: :restrict_with_exception

  validates :title, :public_id, presence: true
  validates :public_id, uniqueness: true
  validates :screenshot_licence, exclusion: { in: [ nil ] }
  validate :public_id_is_stable, on: :update
  validate :valid_title_aliases

  after_update :touch_releases

  private
    def valid_title_aliases
      unless title_aliases.is_a?(Array) && title_aliases.all? { |title| title.is_a?(String) && title.present? } && title_aliases.uniq == title_aliases
        errors.add(:title_aliases, "must be distinct nonblank titles")
      end
    end

    def touch_releases
      releases.touch_all
    end

    def public_id_is_stable
      errors.add(:public_id, "cannot change") if public_id_changed?
    end
end
