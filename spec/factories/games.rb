FactoryBot.define do
  factory :game do
    sequence(:public_id) { |n| "game-#{n}" }
    title { "A game" }
  end
end
