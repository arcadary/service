require "rails_helper"

RSpec.describe CompatibilityResultDecorator do
  let(:result) { create(:compatibility_result, requires_input: [ "keyboard" ]) }

  it "shapes a result as the public device entry and the internal history entry" do
    expect(described_class.decorate(result).as_json).to eq(
      "status" => "works", "reason" => nil, "core" => "sameboy", "core_version" => "1.0.2", "startup_revision" => result.startup_revision,
      "tested_at" => "2026-11-20T18:00:00Z", "observed" => "Played the first level with sound and a battery save.", "limits" => "Later levels not reached.", "requires_input" => [ "keyboard" ])
    expect(described_class.decorate(result).history_json).to eq(described_class.decorate(result).as_json.merge(
      "id" => result.id, "device" => "steam_machine", "sha1" => result.sha1, "reviewer" => "Synthetic Reviewer", "video_ids" => [], "recorded_at" => result.created_at.utc.iso8601(6)))
  end

  it "shows a device with no result or a withdrawn one as unknown" do
    withdrawn = create(:compatibility_result, status: "unknown")
    expect(described_class.current("steam_machine" => withdrawn, "steam_deck" => nil)).to eq(
      "steam_machine" => { "status" => "unknown" }, "steam_deck" => { "status" => "unknown" })
  end
end
