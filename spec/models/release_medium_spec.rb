require "rails_helper"

RSpec.describe ReleaseMedium, type: :model do
  let(:release) { create(:release) }

  it "keeps keys and consecutive positions unique within a release while allowing shared files" do
    medium = create(:release_medium, release: release)
    expect(build(:release_medium, release: release, position: 3)).not_to be_valid
    expect(build(:release_medium, release: release, key: "other")).not_to be_valid
    expect(build(:release_medium, release: release, key: "gap", position: 4)).not_to be_valid
    other = create(:release)
    expect(create(:release_medium, release: other, media_file: medium.media_file)).to be_persisted
  end

  it "validates the public medium fields" do
    medium = build(:release_medium, release: release)
    expect(medium).to be_valid
    [ { key: "Side A" }, { position: 0 }, { label: "a" * 81 }, { role: "boot" } ].each do |attributes|
      expect(build(:release_medium, release: release, **attributes)).not_to be_valid
    end
  end

  it "keeps the release's legacy checksum equal to its first medium" do
    medium = release.release_media.first
    medium.update!(media_file: create(:media_file))
    expect(release.reload.sha1).to eq(medium.media_file.sha1)
  end
end
