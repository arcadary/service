class Game < ApplicationRecord
  has_many :releases, dependent: :restrict_with_exception

  validates :title, :public_id, presence: true
  validates :public_id, uniqueness: true
  validate :public_id_is_stable, on: :update

  after_update :touch_releases

  private
    def touch_releases
      releases.touch_all
    end

    def public_id_is_stable
      errors.add(:public_id, "cannot change") if public_id_changed?
    end
end
