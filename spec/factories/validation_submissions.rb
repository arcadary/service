FactoryBot.define do
  factory :validation_submission do
    sha1 { "a" * 40 }
    byte_size { 20 }
    system { "c64" }
  end
end
