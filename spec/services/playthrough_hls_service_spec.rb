require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe PlaythroughHlsService do
  include PlaythroughHlsHelpers

  def validate_files(files:, types: {})
    entries = files.map { |name, _bytes| UploadFile.new(name: name, content_type: types.fetch(name) { hls_content_type(name) }) }
    described_class.validate(files: entries, reader: ->(path:) { files.fetch(path) })
  end

  it "validates a chaptered variant graph with BOM and numerically equal durations" do
    result = validate_files(files: hls_variant_files)
    expect(result).to eq("duration" => "2.5", "video_codec" => "h264", "audio_codec" => "aac",
      "chapters" => [ { "start" => "00:00:00.000", "end" => "00:00:02.500", "title" => "First chapter" } ])
  end

  it "accepts silent H.264, absent chapters and variants sharing a media playlist" do
    files = { "index.m3u8" => hls_master(paths: [ "low/index.m3u8", "low/index.m3u8" ]),
      "low/index.m3u8" => hls_media, "low/segment.ts" => hls_transport(audio: false) }
    expect(validate_files(files: files)).to include("audio_codec" => nil, "chapters" => [])
  end

  it "rejects mismatched variant durations and segment counts" do
    files = hls_variant_files
    files["high/index.m3u8"] = hls_media(segments: [ [ "segment.ts", "2.4" ] ])
    expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
    files["high/index.m3u8"] = hls_media(segments: [ [ "segment.ts", "1.25" ], [ "segment.ts", "1.25" ] ])
    expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
  end

  it "rejects audio presence changes between variants or within one playlist" do
    files = hls_variant_files.merge("high/segment.ts" => hls_transport(audio: false))
    expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
    files = hls_files.merge("silent.ts" => hls_transport(audio: false),
      "index.m3u8" => hls_media(segments: [ [ "segment.ts", "2.5" ], [ "silent.ts", "2.5" ] ]))
    expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
  end

  it "rejects nested masters and cycles" do
    files = hls_variant_files.merge("low/index.m3u8" => hls_master(paths: [ "child.m3u8" ]))
    expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
    expect { validate_files(files: { "index.m3u8" => hls_master(paths: [ "index.m3u8" ]) }) }.to raise_error(Playthrough::InvalidHls)
  end

  it "rejects undeclared references, unreachable objects and a missing fixed root" do
    expect { validate_files(files: hls_files.except("segment.ts")) }.to raise_error(Playthrough::InvalidHls)
    expect { validate_files(files: hls_files.merge("unused.ts" => hls_transport)) }.to raise_error(Playthrough::InvalidHls)
    expect { validate_files(files: { "other.m3u8" => hls_media }) }.to raise_error(Playthrough::InvalidHls)
  end

  [ "/segment.ts", "https://example.test/segment.ts", "../segment.ts", "video/./segment.ts", "video//segment.ts",
    "segment%2ets", "segment.ts?token=private", "segment.ts#fragment", "video\\segment.ts" ].each do |uri|
    it "rejects unsafe reference #{uri.inspect}" do
      files = hls_files.merge("index.m3u8" => hls_media(segments: [ [ uri, "2.5" ] ]))
      expect { validate_files(files: files) }.to raise_error(Playthrough::InvalidHls)
    end
  end

  [ [ "index.m3u8", "text/plain" ], [ "segment.ts", "video/mp4" ], [ "chapters.vtt", "text/plain" ] ].each do |path, type|
    it "rejects the wrong declared MIME for #{path}" do
      files = hls_files.merge("chapters.vtt" => "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nChapter\n")
      expect { validate_files(files: files, types: { path => type }) }.to raise_error(Playthrough::InvalidHls)
    end
  end
end
