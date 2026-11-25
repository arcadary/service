require "rails_helper"

RSpec.describe Game, type: :model do
  subject { Game.new(public_id: "a-game", title: "A game") }

  it { is_expected.to have_many(:releases).dependent(:restrict_with_exception) }
  it { is_expected.to validate_presence_of(:title) }
  it { is_expected.to validate_presence_of(:public_id) }
  it { is_expected.to validate_uniqueness_of(:public_id) }

  it "keeps its public ID once created" do
    game = Game.create!(public_id: "stable-game", title: "A game")
    expect(game.update(public_id: "new-id")).to be(false)
    expect(game.reload.public_id).to eq("stable-game")
  end

  it "touches its releases when it changes" do
    game = Game.create!(public_id: "touched-game", title: "A game")
    release = game.releases.create!(sha1: "c" * 40, system: "gb")
    expect { game.update!(title: "Renamed") }.to(change { release.reload.updated_at })
  end
end
