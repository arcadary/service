require "rails_helper"

RSpec.describe CompatibilityService do
  let(:release) { create(:release) }
  let(:verdict) do
    { release_id: release.public_id, device_class: "steam_machine", core: "mesen", core_version: "0.9.9", state: "works",
      tested_at: "2026-11-28T12:00:00Z", evidence: "Played the first two worlds", attested: true, reason: "First test" }
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Admin")
  end

  def record(**changes)
    described_class.record(**verdict.merge(changes))
  end

  it "records a verdict for the release's current launch configuration under the configured admin" do
    expect(record).to have_attributes(reviewer: "Admin", startup_revision: ReleaseStartupService.revision(release: release))
    expect { record(attested: false) }.to raise_error(CompatibilityVerdict::InvalidInput)
    expect { record(tested_at: "yesterday") }.to raise_error(CompatibilityVerdict::InvalidInput)
  end

  it "keeps the newest verdict per environment in force, even across launch configurations, and withdraws with unknown" do
    record
    deck = record(device_class: "steam_deck", state: "does_not_work", evidence: "Black screen after the title with default controls")
    release.update!(startup: { "schema" => 1, "boot" => "main", "drives" => {} })
    retest = record(state: "works_with_issues", limitations: "Slowdown in world 3")
    expect(described_class.current(release: release.reload)).to contain_exactly(retest, deck)

    record(state: "unknown", attested: false, evidence: nil, reason: "Wrong core version noted")
    expect(described_class.current(release: release.reload)).to contain_exactly(deck)
  end

  it "attaches only the release's own playthroughs" do
    own = create(:playthrough, release: release)
    expect(record(playthrough_ids: [ own.public_id ]).playthroughs).to eq([ own ])
    expect { record(playthrough_ids: [ create(:playthrough).public_id ]) }.to raise_error(CompatibilityVerdict::InvalidInput)
  end
end
