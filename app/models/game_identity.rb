class GameIdentity < ApplicationRecord
  belongs_to :game

  validates :key, presence: true, uniqueness: true
end
