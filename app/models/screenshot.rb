class Screenshot < ApplicationRecord
  class InvalidImage < StandardError; end
  class InvalidKind < StandardError; end
  class NotFound < StandardError; end
  class LimitReached < StandardError; end
  class StorageUnavailable < StandardError; end

  KINDS = %w[title gameplay].freeze
  TITLE_POSITION = 0
  GAMEPLAY_LIMIT = 50

  belongs_to :release, touch: true
  belongs_to :blob, class_name: "ActiveStorage::Blob"

  attribute :public_id, :string, default: -> { SecureRandom.uuid }
  attr_readonly :public_id

  validates :public_id, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }
  validates :position, uniqueness: { scope: :release_id }
  validates :position, numericality: { equal_to: TITLE_POSITION }, if: -> { kind == "title" }
  validates :position, numericality: { only_integer: true, in: 1..GAMEPLAY_LIMIT }, if: -> { kind == "gameplay" }
  validates :width, :height, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :sha256, uniqueness: { scope: :release_id }, on: :create
  validates :licence, exclusion: { in: [ nil ] }
end
