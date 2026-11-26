FactoryBot.define do
  factory :game_identity do
    game
    sequence(:key) { |n| JSON.generate([ "gb", "Example #{n}" ]) }
  end
end
