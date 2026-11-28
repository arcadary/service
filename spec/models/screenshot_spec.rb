require "rails_helper"

RSpec.describe Screenshot, type: :model do
  subject { build(:screenshot) }

  it { is_expected.to belong_to(:release).touch(true) }
  it { is_expected.to validate_inclusion_of(:kind).in_array(Screenshot::KINDS) }
  it { is_expected.to validate_uniqueness_of(:public_id) }

  it "allows one title and each image once per release" do
    title = create(:screenshot, kind: "title")
    expect { create(:screenshot, release: title.release, kind: "title") }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { create(:screenshot, release: title.release, sha256: title.sha256, blob: title.blob) }.to raise_error(ActiveRecord::RecordNotUnique)
    expect(create(:screenshot, sha256: title.sha256, blob: title.blob)).to be_persisted
  end
end
