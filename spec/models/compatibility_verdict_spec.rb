require "rails_helper"

RSpec.describe CompatibilityVerdict, type: :model do
  subject { described_class.new(state: "works") }

  it { is_expected.to belong_to(:release).touch(true) }
  it { is_expected.to validate_inclusion_of(:state).in_array(described_class::STATES) }
  it { is_expected.to validate_inclusion_of(:device_class).in_array(described_class::DEVICE_CLASSES) }
  it { is_expected.to validate_presence_of(:evidence) }
  it { is_expected.to validate_acceptance_of(:attested) }
  it { is_expected.to validate_length_of(:evidence).is_at_most(described_class::TEXT_LENGTH) }

  it "needs limitations for works_with_issues and neither evidence nor attestation for unknown" do
    expect(described_class.new(state: "works_with_issues")).to validate_presence_of(:limitations)
    expect(described_class.new(state: "unknown")).not_to validate_presence_of(:evidence)
    expect(described_class.new(state: "unknown")).not_to validate_acceptance_of(:attested)
  end
end
