require "rails_helper"

RSpec.describe Upload, type: :model do
  it { is_expected.to have_many(:files).class_name("UploadFile").dependent(:delete_all) }
  it { is_expected.to validate_inclusion_of(:kind).in_array(%w[screenshot video]) }
  it { is_expected.to validate_inclusion_of(:state).in_array(Upload::STATES) }
end

RSpec.describe UploadFile, type: :model do
  it { is_expected.to belong_to(:upload) }

  it "accepts package-relative names and refuses anything that could leave the upload's folder" do
    expect(%w[index.m3u8 low/segment-0001.ts chapters.vtt].all? { |name| described_class.valid_name?(name) }).to be(true)
    expect([ "../index.m3u8", "/index.m3u8", "low//a.ts", "a b.ts", "a\\b.ts" ].none? { |name| described_class.valid_name?(name) }).to be(true)
  end
end

RSpec.describe Video, type: :model do
  subject { build(:video) }

  it { is_expected.to belong_to(:release).touch(true) }
  it { is_expected.to validate_uniqueness_of(:kind).scoped_to(:release_id) }
  it { is_expected.to have_and_belong_to_many(:compatibility_results) }
  it { is_expected.to validate_inclusion_of(:kind).in_array(Video::KINDS) }
end
