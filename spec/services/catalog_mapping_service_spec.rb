require "rails_helper"

RSpec.describe CatalogMappingService do
  it "reads the versioned format, preserving curated titles and explicit ports" do
    mapping = described_class.new(text: "# ignored\ntetris-tengen Tetris (Tengen)\n  #{'A' * 40} # USA\n  #{'b' * 40}\n").mappings
    expect(mapping.keys).to eq([ "a" * 40, "b" * 40 ])
    expect(mapping.values.uniq).to eq([ { public_id: "tetris-tengen", title: "Tetris (Tengen)", checksums: [ "a" * 40, "b" * 40 ] } ])
  end

  it "rejects invalid IDs, orphan checksums, duplicate IDs/checksums and empty games before writes" do
    [ "Bad_id Title\n  #{'a' * 40}", "  #{'a' * 40}", "same Title\n  #{'a' * 40}\nsame Other\n  #{'b' * 40}", "one One\n  #{'a' * 40}\ntwo Two\n  #{'a' * 40}", "empty Empty" ].each do |text|
      expect { described_class.new(text: text) }.to raise_error(described_class::InvalidMapping)
    end
    expect(Game.count).to eq(0)
  end
end
