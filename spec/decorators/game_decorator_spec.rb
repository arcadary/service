require "rails_helper"

RSpec.describe GameDecorator do
  it "shapes a game as the public JSON" do
    game = build(:game, public_id: "decorator-game", title: "A game")
    expect(described_class.decorate(game).as_json).to eq(id: "decorator-game", title: "A game", screenshot: nil)
  end
end
