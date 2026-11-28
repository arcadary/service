FactoryBot.define do
  factory :screenshot do
    release
    kind { "gameplay" }
    position { 1 }
    width { 2 }
    height { 2 }
    sequence(:sha256) { |n| Digest::SHA256.hexdigest("screenshot-#{n}") }
    blob do
      ActiveStorage::Blob.create!(key: ScreenshotService.key(sha256: sha256), filename: "screenshot.png", content_type: "image/png",
        byte_size: 1, checksum: "synthetic", service_name: "test_media")
    end
  end
end
