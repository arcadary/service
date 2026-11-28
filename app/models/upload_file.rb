class UploadFile < ApplicationRecord
  belongs_to :upload, inverse_of: :files

  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validate { errors.add(:name, :invalid) unless self.class.valid_name?(name.to_s) }
  attr_readonly :name, :byte_size, :sha256, :content_type

  def self.valid_name?(name)
    /\A[^\s\\:%?#\x00-\x1f\x7f]{1,1024}\z/.match?(name) && name.split("/", -1).none? { |part| [ "", ".", ".." ].include?(part) }
  end
end
