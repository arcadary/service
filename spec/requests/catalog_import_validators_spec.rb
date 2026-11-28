require "rails_helper"
require_relative "../support/catalog_helpers"

RSpec.describe "Imported catalog validators", type: :request do
  include CatalogHelpers
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Dir.mktmpdir("catalog-validators-", Rails.root.join("tmp")) do |folder|
      @folder = folder
      example.run
    end
  end

  def fetch(sha1:, resource: "releases", headers: {})
    get "/v1/#{resource}/#{sha1}.json", headers: headers.merge("User-Agent" => "Arcadary/1.0")
  end

  it "refreshes changed releases, game siblings and media resources while preserving unrelated and repeat validators" do
    entries = [ { title: "Zed (USA)", sha1: checksum(9001), size: 10 }, { title: "Zed (Europe)", sha1: checksum(9002) }, { title: "Unrelated", sha1: checksum(9003) } ]
    travel_to(1.minute.ago) { import_entries(entries: entries) }
    paths = [ [ checksum(9001), "releases" ], [ checksum(9002), "releases" ], [ checksum(9001), "media" ] ]
    validators = (paths + [ [ checksum(9003), "releases" ] ]).to_h do |sha1, resource|
      fetch(sha1: sha1, resource: resource)
      expect(response).to have_http_status(:ok)
      [ [ sha1, resource ], response.headers.slice("ETag", "Last-Modified") ]
    end
    startup = Release.order(:id).map { |release| ReleaseStartupService.revision(release: release) }
    import_entries(entries: [ entries.first.merge(title: "Alpha (Japan)", size: 20) ])
    current = paths.to_h do |sha1, resource|
      old = validators.fetch([ sha1, resource ])
      fetch(sha1: sha1, resource: resource, headers: { "If-None-Match" => old.fetch("ETag") })
      expect(response).to have_http_status(:ok)
      expect(response.headers.fetch("Last-Modified")).not_to eq(old.fetch("Last-Modified"))
      expect(response.headers.fetch("Cache-Control")).to eq("max-age=300, public")
      etag = response.headers.fetch("ETag")
      fetch(sha1: sha1, resource: resource, headers: { "If-Modified-Since" => old.fetch("Last-Modified") })
      expect(response).to have_http_status(:ok)
      fetch(sha1: sha1, resource: resource, headers: { "If-None-Match" => etag })
      expect(response).to have_http_status(:not_modified)
      [ [ sha1, resource ], etag ]
    end
    expect(Release.order(:id).map { |release| ReleaseStartupService.revision(release: release) }).to eq(startup)
    fetch(sha1: checksum(9003), headers: { "If-None-Match" => validators.fetch([ checksum(9003), "releases" ]).fetch("ETag") })
    expect(response).to have_http_status(:not_modified)
    import_entries(entries: [ entries.first.merge(title: "Alpha (Japan)", size: 20) ])
    current.each do |(sha1, resource), etag|
      fetch(sha1: sha1, resource: resource, headers: { "If-None-Match" => etag })
      expect(response).to have_http_status(:not_modified)
    end
  end
end
