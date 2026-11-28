require "rails_helper"

RSpec.describe Release, "controller profiles" do
  let(:profile) { build(:controller_profile) }

  it "validates the supported schema and finite fact and citation bounds" do
    release = build(:release, system: "snes", controller_profile: profile)
    expect(release).to be_valid
    invalid_profiles = [
      profile.merge("version" => 2), profile.merge("version" => "1"), profile.merge("device" => "controller"),
      profile.merge("layout" => "XABY"), profile.merge("prompts" => {}),
      profile.merge("binding" => profile["binding"].merge("region" => "Europe")),
      profile.merge("layout" => profile["layout"].first(3)),
      profile.merge("layout" => [ profile["layout"].first ] * 4),
      profile.merge("prompts" => [ profile["prompts"].first.merge("position" => "shoulder") ]),
      profile.merge("prompts" => [ profile["prompts"].first.merge("letter" => 1) ]),
      profile.merge("prompts" => [ profile["prompts"].first.merge("letter" => "Press A") ]),
      profile.merge("prompts" => [ profile["prompts"].first ] * 2),
      profile.merge("prompts" => ("A".."Q").map { |letter| profile["prompts"].first.merge("letter" => letter) }),
      profile.merge("prompts" => [ profile["prompts"].first.merge("evidence" => []) ]),
      profile.merge("prompts" => [ profile["prompts"].first.merge("evidence" => [ { "image" => "unsupported" } ]) ]),
      profile.merge("prompts" => [ profile["prompts"].first.merge("evidence" => [ "citation" ] * 9) ]),
      profile.merge("prompts" => [ profile["prompts"].first.merge("evidence" => [ "x" * 501 ]) ])
    ]
    invalid_profiles.each do |invalid|
      release.controller_profile = invalid
      expect(release).not_to be_valid
      expect(release.errors[:controller_profile]).to be_present
    end
    release.assign_attributes(controller_profile: profile, system: "nes")
    expect(release).not_to be_valid
    release.assign_attributes(system: "snes", region: "x" * 129,
      controller_profile: profile.merge("binding" => profile["binding"].merge("region" => "x" * 129)))
    expect(release).not_to be_valid
  end

  it "retains different prompt letters for two exact editions without filling absent facts" do
    first = create(:release, system: "snes", controller_profile: profile)
    second_profile = build(:controller_profile, binding: { "system" => "snes", "region" => "Japan", "revision" => "Rev 1" },
      prompts: [ { "letter" => "B", "position" => "right", "evidence" => [ "Synthetic second edition observation" ] } ])
    second = create(:release, game: first.game, system: "snes", region: "Japan", revision: "Rev 1", controller_profile: second_profile)
    absent = create(:release, game: first.game, system: "snes")
    expect(first.reload.controller_profile.dig("prompts", 0, "letter")).to eq("A")
    expect(second.reload.controller_profile).to eq(second_profile)
    expect(absent.reload.controller_profile).to be_nil
  end
end
