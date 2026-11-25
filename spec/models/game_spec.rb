require "rails_helper"

RSpec.describe Game, type: :model do
  subject { build(:game) }

  it { is_expected.to have_many(:releases).dependent(:restrict_with_exception) }
  it { is_expected.to validate_presence_of(:title) }
  it { is_expected.to validate_presence_of(:public_id) }
  it { is_expected.to validate_uniqueness_of(:public_id) }

  it "keeps its public ID once created" do
    game = create(:game, public_id: "stable-game")
    expect(game.update(public_id: "new-id")).to be(false)
    expect(game.reload.public_id).to eq("stable-game")
  end

  it "touches its releases when it changes" do
    game = create(:game, public_id: "touched-game")
    release = create(:release, game: game, sha1: "c" * 40, system: "gb")
    expect { game.update!(title: "Renamed") }.to(change { release.reload.updated_at })
  end
end
