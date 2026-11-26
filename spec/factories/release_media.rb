FactoryBot.define do
  factory :release_medium do
    release
    media_file
    key { "disk-2" }
    position { 2 }
    label { "Disk 2" }
    role { "game" }
  end
end
