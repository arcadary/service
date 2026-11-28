require "rails_helper"

RSpec.describe ReleaseDecorator do
  it "shapes a release and its game as the public JSON" do
    game = create(:game, public_id: "decorator-game")
    release = create(:release, game: game, sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "gb", region: "EU")

    expect(described_class.decorate(release).as_json).to eq(
      release: { "id" => release.public_id, "sha1" => release.sha1, "system" => "gb", "region" => "EU", "revision" => nil, "screenshots" => [] },
      game: { id: "decorator-game", title: "A game", screenshot: nil },
      media: [ { "key" => "main", "position" => 1, "label" => nil, "role" => "game", "sha1" => release.sha1, "size" => nil, "format" => nil } ],
      startup: { "schema" => 1, "boot" => "main", "drives" => {}, "revision" => "94913af33af735c08211b2d614136735f0f855ec9173709238d451b97cbfed95" },
      compatibility: { "default_state" => "unknown", "results" => [] }
    )
  end
end
