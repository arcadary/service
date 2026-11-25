require "rails_helper"

RSpec.describe ReleaseService do
  let(:game) { Game.create!(public_id: "service-game", title: "A game") }
  let!(:release) { game.releases.create!(sha1: "abcdef0123456789abcdef0123456789abcdef01", system: "c64") }

  it "finds a release by its SHA-1" do
    expect(described_class.find_by(sha1: release.sha1)).to eq(release)
  end

  it "accepts upper-case hex" do
    expect(described_class.find_by(sha1: release.sha1.upcase)).to eq(release)
  end

  it "raises InvalidSha1 for a malformed checksum" do
    [ "a" * 39, "a" * 41, "g" * 40, "", nil ].each do |sha1|
      expect { described_class.find_by(sha1: sha1) }.to raise_error(Release::InvalidSha1)
    end
  end

  it "raises ReleaseNotFound for an unknown checksum" do
    expect { described_class.find_by(sha1: "0" * 40) }.to raise_error(Release::ReleaseNotFound)
  end
end
