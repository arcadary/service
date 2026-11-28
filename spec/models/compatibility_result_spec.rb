require "rails_helper"

RSpec.describe CompatibilityResult, type: :model do
  subject { build(:compatibility_result) }

  it { is_expected.to belong_to(:release).touch(true) }
  it { is_expected.to validate_inclusion_of(:device).in_array(CompatibilityResult::DEVICES) }
  it { is_expected.to validate_inclusion_of(:status).in_array(CompatibilityResult::STATUSES) }
  it { is_expected.not_to allow_value("Mesen 2").for(:core) }
  it { is_expected.to validate_length_of(:observed).is_at_most(CompatibilityResult::TEXT_LENGTH) }
  it { is_expected.to validate_presence_of(:limits) }
  it { is_expected.not_to allow_value([ "light_gun" ]).for(:requires_input) }

  it "keeps a recorded result unchanged" do
    result = create(:compatibility_result)
    expect { result.update!(status: "broken") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
