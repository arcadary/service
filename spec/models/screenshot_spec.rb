require "rails_helper"

RSpec.describe Screenshot, type: :model do
  subject { build(:screenshot) }

  it { is_expected.to belong_to(:release).touch(true) }
  it { is_expected.to validate_inclusion_of(:kind).in_array(Screenshot::KINDS) }
  it { is_expected.to validate_uniqueness_of(:position).scoped_to(:release_id) }
  it { is_expected.to validate_uniqueness_of(:sha256).scoped_to(:release_id).on(:create) }
  it { is_expected.to validate_numericality_of(:position).only_integer.is_in(1..Screenshot::GAMEPLAY_LIMIT) }

  it "keeps the title screenshot at position 0, before every gameplay screenshot" do
    expect(build(:screenshot, kind: "title", position: 0)).to be_valid
    expect(build(:screenshot, kind: "title", position: 1)).not_to be_valid
    expect(build(:screenshot, kind: "gameplay", position: 0)).not_to be_valid
  end
end
