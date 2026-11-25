FactoryBot.define do
  factory :release do
    game
    sequence(:sha1) { |n| format("%040x", n) }
    system { "gb" }
  end
end
