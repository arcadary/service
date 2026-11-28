class CompatibilityResult < ApplicationRecord
  class InvalidInput < StandardError; end
  class TargetMismatch < StandardError; end
  class RetryConflict < StandardError; end

  DEVICES = %w[steam_machine steam_deck].freeze
  STATUSES = %w[works attention does_not_work unknown].freeze
  INPUTS = %w[keyboard mouse].freeze
  CORE = /\A[a-z0-9][a-z0-9_.-]{0,63}\z/
  TEXT_LENGTH = 500
  REASON_LENGTH = 200
  SHORT_LENGTH = 100

  belongs_to :release, touch: true
  has_and_belongs_to_many :videos, -> { select(:id, :public_id) }, join_table: :compatibility_result_videos

  validates :device, inclusion: { in: DEVICES }
  validates :status, inclusion: { in: STATUSES }
  validates :sha1, format: { with: /\A[0-9a-f]{40}\z/ }
  validates :startup_revision, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :core, format: { with: CORE }
  validates :core_version, :reviewer, presence: true, length: { maximum: SHORT_LENGTH }
  validates :observed, :limits, presence: true, length: { maximum: TEXT_LENGTH }
  validates :tested_at, :retry_key, :fingerprint, presence: true
  validates :reason, presence: true, length: { maximum: REASON_LENGTH }, if: -> { status == "attention" }
  validates :reason, length: { maximum: REASON_LENGTH }, if: -> { status == "does_not_work" }
  validates :reason, absence: true, if: -> { %w[works unknown].include?(status) }
  validate :known_inputs

  def readonly?
    persisted?
  end

  private
    def known_inputs
      unless requires_input.is_a?(Array) && requires_input.all? { |input| INPUTS.include?(input) } && requires_input.uniq.sort == requires_input
        errors.add(:requires_input, "must be distinct known input devices in order")
      end
    end
end
