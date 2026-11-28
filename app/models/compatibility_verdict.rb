class CompatibilityVerdict < ApplicationRecord
  class InvalidInput < StandardError; end

  STATES = %w[unknown works works_with_issues does_not_work].freeze
  DEVICE_CLASSES = %w[steam_machine steam_deck].freeze
  TEXT_LENGTH = 8000

  belongs_to :release, touch: true
  has_and_belongs_to_many :playthroughs, join_table: :compatibility_verdict_playthroughs

  attribute :attested, :boolean, default: false

  validates :state, inclusion: { in: STATES }
  validates :device_class, inclusion: { in: DEVICE_CLASSES }
  validates :core, :core_version, presence: true, length: { maximum: 100 }
  validates :tested_at, :reviewer, :startup_revision, presence: true
  validates :reason, presence: true, length: { maximum: 2000 }
  validates :evidence, :limitations, length: { maximum: TEXT_LENGTH }
  validates :evidence, presence: true, unless: :unknown?
  validates :limitations, presence: true, if: -> { state == "works_with_issues" }
  validates :attested, acceptance: { accept: true }, unless: :unknown?

  def readonly?
    persisted?
  end

  def unknown?
    state == "unknown"
  end

  def environment
    [ device_class, core, core_version ]
  end
end
