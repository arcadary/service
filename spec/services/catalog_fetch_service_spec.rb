require "rails_helper"
require "tmpdir"

RSpec.describe CatalogFetchService do
  around do |example|
    Dir.mktmpdir("catalog-fetch-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  it "downloads only the eight allowlisted pinned URLs, verifies bytes and saves locally" do
    manifest = described_class::MANIFEST.deep_dup
    manifest.fetch("systems").each_value { |entry| entry["sha256"] = Digest::SHA256.hexdigest("synthetic metadata") }
    stub_const("CatalogFetchService::MANIFEST", manifest)
    urls = []
    fake = ->(url) { urls << url; "synthetic metadata" }
    expect(described_class.fetch(folder: @folder, downloader: fake)).to eq(8)
    expect(urls.size).to eq(8)
    expect(urls).to all(start_with("https://raw.githubusercontent.com/libretro/libretro-database/f89f09cbe13f9f7863ecf20d0ebf2c5ce53be029/metadat/no-intro/"))
    expect(Dir.children(@folder).sort).to eq(manifest.fetch("systems").values.map { |entry| entry.fetch("file") }.sort)
    expect(File.read(File.join(@folder, "Commodore - 64.dat"))).to eq("synthetic metadata")
  end

  it "refuses unknown files before calling the downloader" do
    fake = double("downloader")
    expect(fake).not_to receive(:call)
    expect { described_class.fetch(folder: @folder, files: [ "../other.dat" ], downloader: fake) }.to raise_error(described_class::FetchFailed, /allowlist/)
    expect(Dir.children(@folder)).to eq([])
  end

  it "leaves prior verified files intact on digest mismatch or download failure" do
    file = "Commodore - 64.dat"
    path = File.join(@folder, file)
    File.write(path, "previous verified bytes")
    expect { described_class.fetch(folder: @folder, files: [ file ], downloader: ->(_) { "wrong bytes" }) }.to raise_error(described_class::FetchFailed, /SHA-256 mismatch/)
    expect { described_class.fetch(folder: @folder, files: [ file ], downloader: ->(_) { raise IOError, "network unavailable" }) }.to raise_error(IOError)
    expect(File.read(path)).to eq("previous verified bytes")
    expect(Dir.children(@folder)).to eq([ file ])
  end
end
