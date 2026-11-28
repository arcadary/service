require "rails_helper"

RSpec.describe CompatibilityService do
  include ActiveSupport::Testing::TimeHelpers

  let(:release) { create(:release) }

  def arguments(**overrides)
    {
      release_id: release.public_id, sha1: release.sha1.upcase, device: "steam_machine", status: "works", core: "sameboy", core_version: "1.0.2",
      startup_revision: ReleaseStartupService.revision(release: release), tested_at: "2026-11-20T19:00:00+01:00",
      observed: "Played the first level with sound.", limits: "Later levels not reached.", reviewer: "Synthetic Reviewer",
      owns_file: true, retry_key: "machine-1"
    }.merge(overrides)
  end

  describe ".record" do
    it "appends a result for the exact file and configuration and moves the release's timestamp" do
      travel_to(Time.utc(2026, 11, 20, 12)) { release }
      travel_to(Time.utc(2026, 11, 21, 12)) do
        result = described_class.record(**arguments)
        expect(result).to have_attributes(release: release, sha1: release.sha1, device: "steam_machine", status: "works", reviewer: "Synthetic Reviewer",
          tested_at: Time.utc(2026, 11, 20, 18))
        expect(release.reload.updated_at).to eq(Time.current)
      end
    end

    it "keeps a caveat's reason and an optional reason for a broken result" do
      expect(described_class.record(**arguments(status: "works_with_issues", reason: "Slows down when many enemies appear."))).to have_attributes(reason: "Slows down when many enemies appear.")
      expect(described_class.record(**arguments(status: "broken", retry_key: "machine-2"))).to have_attributes(reason: nil)
    end

    it "keeps an input-device requirement separate from the status, in a fixed order" do
      expect(described_class.record(**arguments(requires_input: %w[mouse keyboard]))).to have_attributes(status: "works", requires_input: %w[keyboard mouse])
      expect(described_class.record(**arguments.except(:requires_input).merge(retry_key: "machine-2"))).to have_attributes(requires_input: [])
    end

    it "returns the original result for an identical retry and refuses a changed one with the same key" do
      first = described_class.record(**arguments)
      expect(described_class.record(**arguments)).to eq(first)
      expect { described_class.record(**arguments(status: "broken")) }.to raise_error(CompatibilityResult::RetryConflict)
      expect(CompatibilityResult.count).to eq(1)
    end

    it "refuses an unknown release, a file outside it and a launch configuration that is no longer current" do
      expect { described_class.record(**arguments(release_id: "unknown")) }.to raise_error(Release::ReleaseNotFound)
      expect { described_class.record(**arguments(sha1: create(:release).sha1)) }.to raise_error(CompatibilityResult::TargetMismatch)
      stale = arguments(retry_key: "stale")
      create(:release_medium, release: release)
      expect { described_class.record(**stale) }.to raise_error(CompatibilityResult::TargetMismatch)
    end

    it "refuses a result without the ownership attestation, a time zone, a past test time or printable text" do
      [
        arguments(owns_file: false), arguments(tested_at: "2026-11-28T18:00:00"), arguments(tested_at: 1.hour.from_now.iso8601),
        arguments(observed: "Line one\nLine two"), arguments(limits: " "), arguments(device: "steam_box"), arguments.except(:reviewer),
        arguments(status: "works_with_issues"), arguments(status: "works_with_issues", reason: "Slow\tdown."), arguments(reason: "Plays fine."),
        arguments(status: "broken", reason: "x" * 201), arguments(requires_input: [ "light_gun" ]), arguments(requires_input: %w[keyboard keyboard])
      ].each do |invalid|
        expect { described_class.record(**invalid) }.to raise_error(CompatibilityResult::InvalidInput)
      end
      expect(CompatibilityResult.count).to eq(0)
    end
  end

  describe ".current" do
    it "keeps each device class apart and takes the newest result for the current launch configuration" do
      old = create(:compatibility_result, release: release, status: "broken")
      newer = create(:compatibility_result, release: release, status: "works")
      expect(described_class.current(release: release.reload)).to eq("steam_machine" => newer, "steam_deck" => nil)
      expect(old.reload).to be_present

      create(:release_medium, release: release)
      expect(described_class.current(release: release.reload)).to eq("steam_machine" => nil, "steam_deck" => nil)
    end
  end
end
