ActiveRecord::Base.transaction do
  [
    { public_id: "ucity", title: "µCity", system: "gbc", sha1: "5f026649611c9606ce0bf70dc1552e054e7df5bc" },
    { public_id: "tobu-tobu-girl", title: "Tobu Tobu Girl", system: "gb", sha1: "8a8f3c1f21f903ea5a7df8fc8b0a6aa5a602e150" }
  ].each do |seed|
    game = Game.find_or_initialize_by(public_id: seed[:public_id])
    game.update!(title: seed[:title])
    release = Release.find_or_initialize_by(sha1: seed[:sha1])
    release.update!(game: game, system: seed[:system], region: nil, revision: nil)
  end
end
