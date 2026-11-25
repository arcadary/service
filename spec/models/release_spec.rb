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

  it "rejects a checksum that is not 40 lower-case hex characters" do
    release.sha1 = "A" * 40
    expect(release).not_to be_valid
  end

  it "accepts a launcher system and rejects any other" do
    release.system = "c64"
    expect(release).to be_valid
    release.system = "psx"
    expect(release).not_to be_valid
  end
end
