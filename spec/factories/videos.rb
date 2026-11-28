FactoryBot.define do
  factory :video do
    public_id { SecureRandom.uuid }
    release
    kind { "playthrough" }
    source_sha1 { release.sha1 }
    capture { { "tool" => "synthetic-capture", "version" => "1", "captured_at" => "2026-11-28T11:00:00.000000Z" } }
    files { [] }
    media { { "format" => "ts", "audio" => true, "duration" => 2.5, "chapters" => [] } }
  end
end
