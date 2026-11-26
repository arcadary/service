ActiveRecord::Base.transaction do
  [
    { public_id: "ucity", title: "µCity", system: "gbc", sha1: "5f026649611c9606ce0bf70dc1552e054e7df5bc" },
    { public_id: "tobu-tobu-girl", title: "Tobu Tobu Girl", system: "gb", sha1: "8a8f3c1f21f903ea5a7df8fc8b0a6aa5a602e150" }
  ].each do |seed|
    next if Release.exists?(sha1: seed[:sha1])

    game = Game.find_or_create_by!(public_id: seed[:public_id]) { |record| record.title = seed[:title] }
    Release.create!(sha1: seed[:sha1], game: game, system: seed[:system])
  end
end
