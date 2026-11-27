require "rails_helper"

RSpec.describe ValidationSubmission, type: :model do
  subject { build(:validation_submission) }

  it { is_expected.to validate_presence_of(:sha1) }
  it { is_expected.to validate_uniqueness_of(:sha1) }
  it { is_expected.to validate_inclusion_of(:system).in_array(Release::SYSTEMS) }
  it { is_expected.to validate_numericality_of(:byte_size).only_integer.is_greater_than(0).is_less_than_or_equal_to(134_217_728) }

  it "keeps admitted facts immutable while completion can be recorded" do
    submission = create(:validation_submission)
    expect(submission.update(completed_at: Time.current)).to be(true)
    expect(submission.update(system: "nes")).to be(false)
    expect(submission.reload.system).to eq("c64")
  end
end
