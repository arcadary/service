class Release < ApplicationRecord
  class InvalidSha1 < StandardError; end
  class ReleaseNotFound < StandardError; end

  SYSTEMS = %w[nes snes gb gbc megadrive pcengine atari2600 c64].freeze

  belongs_to :game, touch: true

  validates :sha1, presence: true, uniqueness: true,
    format: { with: /\A[0-9a-f]{40}\z/ }
  validates :system, inclusion: { in: SYSTEMS }
end
