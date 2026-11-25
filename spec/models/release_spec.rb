require "rails_helper"

RSpec.describe Release, type: :model do
  let(:game) { Game.create!(public_id: "test-game", title: "A game") }
  subject(:release) { game.releases.build(sha1: "a" * 40, system: "gb") }

  it "requires an existing game" do
    release.game = nil
    expect(release).not_to be_valid
    expect(release.errors[:game]).to be_present
  end

  it "touches its game when it changes" do
    game = Game.create!(public_id: "touching-game", title: "A game")
    release = game.releases.create!(sha1: "d" * 40, system: "gb")
    expect { release.update!(region: "Europe") }.to(change { game.reload.updated_at })
  end

  it "requires a unique checksum" do
    release.save!
    duplicate = game.releases.build(sha1: release.sha1, system: "gbc")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:sha1]).to be_present
  end

  [ nil, "", "a" * 39, "a" * 41, "g" * 40, "A" * 40, "a" * 40 + "\n" ].each do |checksum|
    it "rejects checksum #{checksum.inspect}" do
      release.sha1 = checksum
      expect(release).not_to be_valid
    end
  end

  %w[nes snes gb gbc megadrive pcengine atari2600 c64].each do |system|
    it "accepts the #{system} system with optional region and revision" do
      release.system = system
      expect(release).to be_valid
    end
  end

  [ nil, "", "GB", "psx" ].each do |system|
    it "rejects system #{system.inspect}" do
      release.system = system
      expect(release).not_to be_valid
      expect(release.errors[:system]).to be_present
    end
  end
end
