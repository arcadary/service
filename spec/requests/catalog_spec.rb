require "rails_helper"
require_relative "../support/catalog_helpers"

RSpec.describe "Imported catalog lookups", type: :request do
  include CatalogHelpers

  around do |example|
    Dir.mktmpdir("catalog-request-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  def etag_for(sha1:)
    get "/v1/releases/#{sha1}.json", headers: { "User-Agent" => "Arcadary/1.0" }
    expect(response).to have_http_status(:ok)
    response.headers.fetch("ETag")
  end

  it "uses one indexed existence read for populated lookup and follows to the same release/game shape" do
    import_entries(entries: (1..150).map { |number| { title: "Game #{number} (World)", sha1: checksum(number) } })
    queries = []
    subscriber = ->(*args) { payload = args.last; queries << payload[:sql] if payload[:sql].match?(/\ASELECT/i) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get "/v1/lookup/#{checksum(90)}.json", headers: { "User-Agent" => "Arcadary/1.0" }
    end
    expect(queries.size).to eq(1)
    expect(queries.sole).to match(/SELECT 1 AS one FROM "releases" WHERE "releases"\."sha1" = .* LIMIT/)
    plan = Release.connection.execute("EXPLAIN QUERY PLAN SELECT 1 FROM releases WHERE sha1 = '#{checksum(90)}' LIMIT 1")
    expect(plan.first.fetch("detail")).to include("index_releases_on_sha1")
    expect(response).to have_http_status(:moved_permanently)
    expect(response.headers["Cache-Control"]).to eq("max-age=86400, public")
    follow_redirect!
    expect(response.parsed_body).to eq("game" => { "id" => Release.find_by!(sha1: checksum(90)).game.public_id, "title" => "Game 90" }, "release" => { "sha1" => checksum(90), "system" => "nes", "region" => "World", "revision" => nil })
    expect(response.headers["Cache-Control"]).to eq("max-age=300, public")
    expect(response.headers["Set-Cookie"]).to be_nil
  end

  it "invalidates all responses containing a changed game title while preserving unrelated and repeat validators" do
    entries = [ { title: "Zed (USA)", sha1: checksum(1) }, { title: "Zed (Europe)", sha1: checksum(2) }, { title: "Other (World)", sha1: checksum(3) } ]
    import_entries(entries: entries)
    etags = (1..3).to_h { |number| [ number, etag_for(sha1: checksum(number)) ] }
    before = snapshot
    import_entries(entries: entries)
    expect(snapshot).to eq(before)
    expect(etag_for(sha1: checksum(1))).to eq(etags[1])
    import_entries(entries: [ { title: "Alpha (USA)", sha1: checksum(1) } ])
    expect(etag_for(sha1: checksum(1))).not_to eq(etags[1])
    expect(etag_for(sha1: checksum(2))).not_to eq(etags[2])
    expect(response.parsed_body.dig("game", "title")).to eq("Alpha")
    expect(etag_for(sha1: checksum(3))).to eq(etags[3])
    unchanged_sibling = etag_for(sha1: checksum(2))
    import_entries(entries: [ { title: "Alpha (USA) (Rev 1)", sha1: checksum(1) } ])
    expect(etag_for(sha1: checksum(2))).to eq(unchanged_sibling)
    expect(Release.find_by!(sha1: checksum(1)).revision).to eq("Rev 1")
  end
end
