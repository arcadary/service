require "rails_helper"

RSpec.describe MediaFile, type: :model do
  subject { build(:media_file) }

  it { is_expected.to validate_uniqueness_of(:sha1) }
  it { is_expected.not_to allow_value("A" * 40).for(:sha1) }
  it { is_expected.to validate_numericality_of(:size).only_integer.is_greater_than_or_equal_to(0).allow_nil }
  it { is_expected.not_to allow_value("D64").for(:format) }
  it { is_expected.not_to allow_value("not-a-checksum").for(:crc32) }
  it { is_expected.not_to allow_value("not-a-checksum").for(:md5) }
end
