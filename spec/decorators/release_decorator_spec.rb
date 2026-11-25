require "rails_helper"

RSpec.describe ReleaseDecorator do
  it "shapes a release and its game as the public JSON" do
    game = Game.create!(public_id: "decorator-game", title: "A game")
    release = game.releases.create!(sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "gb", region: "EU")

    expect(described_class.decorate(release).as_json).to eq(
      release: { "sha1" => release.sha1, "system" => "gb", "region" => "EU", "revision" => nil },
      game: { id: "decorator-game", title: "A game" }
    )
  end
end
