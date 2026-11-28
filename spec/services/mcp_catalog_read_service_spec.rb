require "rails_helper"

RSpec.describe McpCatalogReadService do
  def read(tool:, **arguments)
    described_class.call(tool: tool, **arguments)
  end

  def next_page(tool:, page:)
    read(tool: tool, cursor: page.fetch("next_cursor"))
  end

  it "searches aliases and system with deterministic continuation pages" do
    games = 3.times.map { |index| create(:game, public_id: "search-#{index}", title_aliases: [ "Synthetic alias" ]) }
    games.each { |game| create(:release, game: game, system: "c64") }
    create(:release, game: create(:game, title: "Synthetic alias"), system: "gb")
    page = read(tool: "search_games", query: "ALIAS", system: "c64", limit: 2)
    expect(page.fetch("items").map { |item| item.fetch("id") }).to eq(games.first(2).map(&:public_id))
    final = next_page(tool: "search_games", page: page)
    expect(final.fetch("items").map { |item| item.fetch("id") }).to eq([ games.last.public_id ])
    expect(final.fetch("next_cursor")).to be_nil
  end

  it "pages nested aliases and variants independently at the default bound" do
    aliases = 21.times.map { |index| format("Alias %02d", index) }
    game = create(:game, title_aliases: aliases.reverse, authored_fields: [ "title_aliases" ])
    releases = 21.times.map { create(:release, game: game) }.sort_by(&:public_id)
    data = read(tool: "get_game", id: game.public_id)
    alias_page = data.dig("canonical", "title_aliases")
    expect(alias_page.fetch("items")).to eq(aliases.first(20))
    expect(next_page(tool: "get_game", page: alias_page)).to eq("items" => [ aliases.last ], "next_cursor" => nil)
    expect(data.dig("releases", "items").map { |item| item.fetch("id") }).to eq(releases.first(20).map(&:public_id))
    expect(next_page(tool: "get_game", page: data.fetch("releases")).fetch("items").map { |item| item.fetch("id") }).to eq([ releases.last.public_id ])
    expect(data.fetch("authored_fields")).to eq("items" => [ "title_aliases" ], "next_cursor" => nil)
  end

  it "pages exact ordered media while retaining effective startup, provenance and authoring revisions" do
    release = create(:release, system: "c64", source_title: "Original (Europe)", source_region: "Europe", region: "World", authored_fields: [ "region" ], authoring_revision: 3)
    20.times { |index| create(:release_medium, release: release, position: index + 2, key: "disk-#{index + 2}") }
    release.reload
    data = read(tool: "get_release", id: release.public_id)
    media = data.dig("canonical", "media")
    expect(media.fetch("items").map { |item| item.fetch("sha1") }).to eq(release.media_files.first(20).map(&:sha1))
    expect(next_page(tool: "get_release", page: media).fetch("items").sole).to include("position" => 21)
    expect(data.fetch("source")).to include("source_region" => "Europe", "source_title" => "Original (Europe)")
    expect(data.fetch("canonical")).to include("region" => "World", "startup" => ReleaseStartupService.for_release(release: release))
    expect(data.fetch("authoring_revision")).to eq(3)
  end

  it "returns paginated candidates for shared checksums and selects an exact stable release id" do
    first = create(:release)
    others = 2.times.map { create(:release_medium, media_file: first.media_files.sole).release }
    page = nil
    expect { read(tool: "get_release", sha1: first.sha1.upcase, limit: 2) }.to raise_error(described_class::AmbiguousRelease) { |error| page = error.candidates }
    final = nil
    expect { next_page(tool: "get_release", page: page) }.to raise_error(described_class::AmbiguousRelease) { |error| final = error.candidates }
    expect((page.fetch("items") + final.fetch("items")).map { |item| item.fetch("id") }).to eq([ first, *others ].map(&:public_id).sort)
    expect(final.fetch("next_cursor")).to be_nil
    expect(read(tool: "get_release", id: others.last.public_id).fetch("id")).to eq(others.last.public_id)
  end

  it "pages audit history and every nested before/after collection without dropping records" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CATALOG_ADMIN_NAME").and_return("Synthetic Owner")
    game = create(:game)
    3.times do |index|
      CatalogAuthoringService.call(operation: :correct_game, attributes: { id: game.public_id, title_aliases: [ "Alias A", "Alias B", "Alias C" ], title: "Revision #{index}" },
        expected_revisions: { "game:#{game.public_id}" => game.reload.authoring_revision },
        reason: "Synthetic audit note", idempotency_key: SecureRandom.uuid)
    end
    page = read(tool: "get_catalog_history", limit: 2)
    expect(page.fetch("items").map { |entry| entry.fetch("id") }).to eq(CatalogMutation.order(id: :desc).limit(2).pluck(:id))
    final = next_page(tool: "get_catalog_history", page: page)
    expect(final.fetch("items").size).to eq(1)
    expect(final.fetch("next_cursor")).to be_nil
    change = page.fetch("items").first.dig("record_changes", "items").first
    aliases = change.dig("after", "canonical", "title_aliases")
    expect(aliases.fetch("items")).to eq([ "Alias A", "Alias B" ])
    expect(next_page(tool: "get_catalog_history", page: aliases)).to eq("items" => [ "Alias C" ], "next_cursor" => nil)
  end

  it "rejects invalid bounds, malformed or cross-tool cursors and changed nested snapshots" do
    expect { read(tool: "search_games", limit: 51) }.to raise_error(described_class::InvalidInput)
    expect { read(tool: "get_release", sha1: "wrong") }.to raise_error(described_class::InvalidInput)
    expect { read(tool: "search_games", cursor: "tampered") }.to raise_error(described_class::InvalidInput)
    game = create(:game, title_aliases: [ "A", "B" ])
    page = read(tool: "get_game", id: game.public_id, limit: 1).dig("canonical", "title_aliases")
    expect { next_page(tool: "get_release", page: page) }.to raise_error(described_class::InvalidInput)
    game.update!(title_aliases: [ "A", "B", "C" ])
    expect { next_page(tool: "get_game", page: page) }.to raise_error(described_class::InvalidInput)
  end

  it "accepts the maximum page and reports absent records" do
    expect(read(tool: "search_games", query: "absent synthetic title", limit: 50)).to eq("items" => [], "next_cursor" => nil)
    expect { read(tool: "get_game", id: "absent") }.to raise_error(described_class::NotFound)
    expect { read(tool: "get_release", sha1: "0" * 40) }.to raise_error(described_class::NotFound)
  end
end
