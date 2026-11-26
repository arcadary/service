require "rails_helper"
require "rake"

RSpec.describe "Bundled homebrew seeds", type: :request do
  before do
    GameIdentity.delete_all
    Release.delete_all
    Game.delete_all
  end

  def expect_seeded_lookups
    expect(Game.count).to eq(2)
    expect(Release.count).to eq(2)
    [
      [ "5f026649611c9606ce0bf70dc1552e054e7df5bc", "ucity", "µCity", "gbc" ],
      [ "8a8f3c1f21f903ea5a7df8fc8b0a6aa5a602e150", "tobu-tobu-girl", "Tobu Tobu Girl", "gb" ]
    ].each do |sha1, public_id, title, system|
      get "/v1/releases/#{sha1}.json"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "game" => { "id" => public_id, "title" => title },
        "release" => { "sha1" => sha1, "system" => system, "region" => nil, "revision" => nil }
      )
    end
  end

  it "seeds an empty database and preserves IDs and records on repeat runs" do
    load Rails.root.join("db/seeds.rb")
    expect_seeded_lookups
    database_ids = [ Game.order(:public_id).pluck(:id), Release.order(:sha1).pluck(:id) ]
    load Rails.root.join("db/seeds.rb")
    expect_seeded_lookups
    expect([ Game.order(:public_id).pluck(:id), Release.order(:sha1).pluck(:id) ]).to eq(database_ids)
  end

  it "replants only the two fixed-ID seeds offline after imported metadata exists" do
    game = create(:game, public_id: "ucity", title: "uCity")
    create(:release, game: game, sha1: "5f026649611c9606ce0bf70dc1552e054e7df5bc", system: "gbc", region: "World", revision: "v1.3", source_title: "uCity (World) (v1.3)")
    create(:game_identity, game: game, key: '["gbc","uCity"]')
    create(:release)
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:seed:replant")
    Rake::Task["db:seed:replant"].invoke
    expect_seeded_lookups
    expect(GameIdentity.count).to eq(0)
    expect(Release.pluck(:source_title)).to eq([ nil, nil ])
  end
end
