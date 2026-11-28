require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe "Screenshot response validators", type: :request do
  include ScreenshotHelpers

  it "publishes exact release/game objects with the title first, then gameplay in the order it was added" do
    release = create(:release, system: "gb")
    first = upload_screenshot(release: release)
    title = upload_screenshot(release: release, kind: "title", bytes: red_png)
    second = upload_screenshot(release: release, bytes: green_png)
    get "/v1/releases/#{release.sha1}.json"
    objects = [ title, first, second ].map do |screenshot|
      { "kind" => screenshot.kind, "url" => "https://media.example/screenshots/#{screenshot.sha256}.png", "width" => 2, "height" => 2, "licence" => "" }
    end
    expect(response.parsed_body.dig("release", "screenshots")).to eq(objects)
    expect(response.parsed_body.dig("game", "screenshot")).to eq(objects.second)
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
    title = first = second = nil
    [
      -> { title = upload_screenshot(release: selected, kind: "title") },
      -> { first = upload_screenshot(release: selected, bytes: red_png) },
      lambda do
        second = upload_screenshot(release: selected, bytes: green_png)
        ScreenshotService.remove(screenshot_id: first.public_id)
      end,
      -> { ScreenshotService.remove(screenshot_id: second.public_id) },
      -> { ScreenshotService.remove(screenshot_id: title.public_id) }
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

  it "keeps an unchanged sibling response current when a change does not touch the selected game picture" do
    selected = create(:release, public_id: "a", system: "gb")
    other = create(:release, public_id: "z", game: selected.game, system: "gb")
    upload_screenshot(release: selected)
    [
      [ selected, -> { upload_screenshot(release: other, kind: "title") } ],
      [ other, -> { upload_screenshot(release: selected, bytes: red_png) } ]
    ].each do |unchanged, change|
      get "/v1/releases/#{unchanged.sha1}.json"
      etag = response.headers.fetch("ETag")
      change.call
      get "/v1/releases/#{unchanged.sha1}.json", headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:not_modified)
    end
  end
end
