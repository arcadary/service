require "rails_helper"

RSpec.describe GameIdentity, type: :model do
  subject { described_class.new(game: build(:game), key: '["gb","Example"]') }

  it { is_expected.to belong_to(:game) }
  it { is_expected.to validate_presence_of(:key) }
  it { is_expected.to validate_uniqueness_of(:key) }
end
