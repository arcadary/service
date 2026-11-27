require "rails_helper"

RSpec.describe Release, type: :model do
  subject { create(:game, public_id: "a-game").releases.build(sha1: "a" * 40, system: "gb") }

  it { is_expected.to belong_to(:game).touch(true) }
  it { is_expected.to validate_presence_of(:sha1) }
  it { is_expected.to allow_value("a" * 40).for(:sha1) }
  it { is_expected.not_to allow_value("A" * 40).for(:sha1) }
  it { is_expected.to validate_inclusion_of(:system).in_array(Release::SYSTEMS) }

  it "keeps its public ID once created" do
    release = create(:release)
    expect(release.update(public_id: "replacement")).to be(false)
  end

  context "startup" do
    let(:release) { create(:release, system: "c64") }
    let!(:second) { create(:release_medium, release: release) }
    let!(:save_disk) { create(:release_medium, release: release, key: "save", position: 3, role: "save") }

    it "refuses invalid schema, cross-release keys, drive assignments and boot media" do
      other = create(:release)
      create(:release_medium, release: other, key: "foreign")
      valid = { "schema" => 1, "boot" => "main", "drives" => { "8" => "main", "9" => "disk-2" } }
      invalid = [
        valid.merge("boot" => "foreign"), valid.merge("boot" => "missing"),
        valid.merge("drives" => { "10" => "main" }),
        valid.merge("drives" => { "8" => "main", "9" => "main" }),
        valid.merge("boot" => "save", "drives" => { "8" => "save" }),
        valid.merge("drives" => { "8" => "disk-2" }),
        valid.merge("schema" => 2), valid.merge("settings" => {}),
        [], valid.merge("schema" => "1"), valid.merge("boot" => 1), valid.merge("drives" => [])
      ]
      invalid.each do |startup|
        release.startup = startup
        expect(release).not_to be_valid, startup.inspect
      end
      release.startup = valid
      expect(release).to be_valid
      release.system = "gb"
      expect(release).not_to be_valid
      release.startup = { "schema" => 1, "boot" => "main" }
      expect(release).to be_valid
    end

    it "uses the lowest game medium and the first drive as defaults" do
      release.release_media.first.role = "save"
      expect(ReleaseStartupService.effective(release: release)).to eq("schema" => 1, "boot" => "disk-2", "drives" => { "8" => "disk-2" })
    end

    it "revises only for effective startup or ordered checksums" do
      revision = -> { ReleaseStartupService.revision(release: release) }
      original = revision.call
      second.update!(label: "Side B")
      expect(revision.call).to eq(original)
      release.startup = { "drives" => { "8" => "main" }, "boot" => "main", "schema" => 1 }
      expect(revision.call).to eq(original)
      release.startup["drives"]["9"] = "disk-2"
      expect(revision.call).not_to eq(original)
      release.startup = nil
      first = release.release_media.first
      first.position, second.position = second.position, first.position
      expect(revision.call).not_to eq(original)
      first.position, second.position = second.position, first.position
      added = release.release_media.build(key: "extra", position: 4, role: "game", media_file: build(:media_file))
      expect(revision.call).not_to eq(original)
      release.release_media.target.delete(added)
      expect(revision.call).to eq(original)
      release.release_media.target.delete(save_disk)
      expect(revision.call).not_to eq(original)
    end

    it "persists a reordered set atomically through nested replacement and keeps the first checksum" do
      release.reload
      original = ReleaseStartupService.revision(release: release)
      media = release.release_media.to_a
      replacement = media.map { |medium| { id: medium.id, _destroy: true } } + [ media[1], media[0], media[2] ].each_with_index.map do |medium, index|
        medium.attributes.slice("media_file_id", "key", "label", "role").merge("position" => index + 1)
      end
      release.update!(release_media_attributes: replacement)
      release.reload
      expect(release.sha1).to eq(second.media_file.sha1)
      expect(release.release_media.map(&:key)).to eq(%w[disk-2 main save])
      expect(ReleaseStartupService.revision(release: release)).not_to eq(original)
    end

    it "refuses medium changes and removals that invalidate startup" do
      release.update!(startup: { "schema" => 1, "boot" => "main", "drives" => { "8" => "main" } })
      first = release.release_media.first
      expect(first.update(role: "save")).to be(false)
      first.reload
      expect(first.destroy).to be(false)
      expect(release.reload.release_media.size).to eq(3)
    end
  end
end
