require "rails_helper"

RSpec.describe Game, type: :model do
  it "requires a title and a unique public ID" do
    expect(Game.new).not_to be_valid
    game = Game.create!(public_id: "stable-game", title: "Original title")
    duplicate = Game.new(public_id: game.public_id, title: "Other game")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:public_id]).to be_present
  end

  it "keeps its public ID when renamed and rejects reassignment" do
    game = Game.create!(public_id: "stable-game", title: "Original title")
    game.update!(title: "New title")
    expect(game.reload.public_id).to eq("stable-game")
    expect(game.update(public_id: "new-id")).to be(false)
    expect(game.reload.public_id).to eq("stable-game")
  end

  it "owns distinct releases across systems and regions" do
    game = Game.create!(public_id: "stable-game", title: "A game")
    first = game.releases.create!(sha1: "a" * 40, system: "gb", region: "Japan")
    second = game.releases.create!(sha1: "b" * 40, system: "snes", region: "Europe", revision: "Rev A")
    expect(game.releases).to contain_exactly(first, second)
    expect(second.game).to eq(game)
  end
end
