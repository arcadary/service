require "rails_helper"

RSpec.describe CompatibilityResult, type: :model do
  subject { build(:compatibility_result) }

  it { is_expected.to belong_to(:release).touch(true) }

  it "keeps a recorded result unchanged" do
    result = create(:compatibility_result)
    expect { result.update!(status: "does_not_work") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
