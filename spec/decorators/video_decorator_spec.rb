require "rails_helper"

RSpec.describe VideoDecorator do
  let(:video) do
    create(:video, public_id: "synthetic-video", media: { "format" => "fmp4", "audio" => nil, "duration" => 125.5,
      "chapters" => [ { "start" => 0.0, "end" => 125.5, "title" => "Whole game" } ] })
  end

  it "shapes a video as the public release entry and the internal admin entry" do
    public_entry = { "kind" => "playthrough", "url" => "https://media.example/videos/synthetic-video/index.m3u8", "duration" => 125.5,
                     "chapters" => [ { "start" => 0.0, "end" => 125.5, "title" => "Whole game" } ] }
    result = create(:compatibility_result, release: video.release, videos: [ video ])

    expect(described_class.decorate(video).as_json).to eq(public_entry)
    expect(described_class.decorate(video.reload).internal_json).to eq(public_entry.merge(
      "id" => "synthetic-video", "format" => "fmp4", "audio" => nil, "source_sha1" => video.release.sha1,
      "capture" => { "tool" => "synthetic-capture", "version" => "1", "captured_at" => "2026-11-28T11:00:00.000000Z" }, "verification" => nil,
      "files" => 0, "created_at" => video.created_at.utc.iso8601, "compatibility_result_ids" => [ result.id ]))
  end
end
