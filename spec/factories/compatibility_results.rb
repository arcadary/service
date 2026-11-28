FactoryBot.define do
  factory :compatibility_result do
    release
    sha1 { release.sha1 }
    device { "steam_machine" }
    status { "works" }
    core { "sameboy" }
    core_version { "1.0.2" }
    startup_revision { ReleaseStartupService.revision(release: release) }
    tested_at { Time.utc(2026, 11, 20, 18) }
    observed { "Played the first level with sound and a battery save." }
    limits { "Later levels not reached." }
    reviewer { "Synthetic Reviewer" }
    sequence(:retry_key) { |n| "result-#{n}" }
    fingerprint { "synthetic" }
  end
end
