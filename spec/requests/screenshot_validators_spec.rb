require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Screenshot response validators", type: :request do
  include ScreenshotHelpers

  it "publishes exact release/game objects in title-gameplay order" do
    release = create(:release, system: "gb")
    gameplay = upload_screenshot(release: release)
    title = upload_screenshot(release: release, kind: "title")
    get "/v1/releases/#{release.sha1}.json"
    objects = [ title, gameplay ].map do |screenshot|
      { "kind" => screenshot.kind, "url" => "https://media.example/screenshots/#{screenshot.sha256}.png", "width" => 2, "height" => 2, "licence" => "" }
    end
    expect(response.parsed_body.dig("release", "screenshots")).to eq(objects)
    expect(response.parsed_body.dig("game", "screenshot")).to eq(objects.last)
  end

  it "revalidates release and media responses when a sibling outside the media collection changes the game picture" do
    sibling = create(:release, public_id: "z", system: "gb")
    selected = create(:release, public_id: "a", game: sibling.game, system: "gb")
    create(:release_medium, media_file: sibling.media_files.sole)
    urls = [ "/v1/releases/#{selected.sha1}.json", "/v1/media/#{sibling.sha1}.json" ]
    etags = urls.map do |url|
      get url, headers: { "User-Agent" => "Arcadary/1.0" }
      response.headers.fetch("ETag")
    end
    [
      -> { upload_screenshot(release: selected, kind: "title") },
      -> { upload_screenshot(release: selected) },
      -> { upload_screenshot(release: selected, bytes: png(pixel: "\xff\0\0\xff".b)) },
      -> { ScreenshotService.remove(public_id: selected.public_id, kind: "gameplay") },
      -> { ScreenshotService.remove(public_id: selected.public_id, kind: "title") }
    ].each do |change|
      change.call
      urls.each_with_index do |url, index|
        get url, headers: { "If-None-Match" => etags[index] }
        expect(response).to have_http_status(:ok)
        etags[index] = response.headers.fetch("ETag")
        get url, headers: { "If-None-Match" => etags[index] }
        expect(response).to have_http_status(:not_modified)
      end
    end
  end

  it "keeps an unchanged sibling response current when another release does not change the selected game picture" do
    selected = create(:release, public_id: "a", system: "gb")
    other = create(:release, public_id: "z", game: selected.game, system: "gb")
    upload_screenshot(release: selected)
    url = "/v1/releases/#{selected.sha1}.json"
    get url
    etag = response.headers.fetch("ETag")
    upload_screenshot(release: other, kind: "title")
    get url, headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
  end
end
