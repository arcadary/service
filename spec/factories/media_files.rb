FactoryBot.define do
  factory :media_file do
    sequence(:sha1) { |n| Kernel.format("%040x", n + 1_000_000) }
    size { 174848 }
    format { "d64" }
  end
end
