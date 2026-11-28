require "rails_helper"
require_relative "../support/video_hls_helpers"

RSpec.describe VideoHlsService do
  include VideoHlsHelpers

  def validate_files(files:, types: {})
    entries = files.map { |name, bytes| UploadFile.new(name: name, byte_size: bytes.bytesize, content_type: types.fetch(name) { hls_content_type(name) }) }
    described_class.validate(files: entries, reader: ->(path:, range: nil) { range ? files.fetch(path).b.byteslice(range) : files.fetch(path) })
  end

  it "validates a chaptered variant graph with BOM and numerically equal durations" do
    result = validate_files(files: hls_variant_files)
    expect(result).to eq("format" => "ts", "audio" => true, "duration" => 2.5,
      "chapters" => [ { "start" => 0.0, "end" => 2.5, "title" => "First chapter" } ])
  end

  it "accepts silent H.264, absent chapters and variants sharing a media playlist" do
    files = { "index.m3u8" => hls_master(paths: [ "low/index.m3u8", "low/index.m3u8" ]),
      "low/index.m3u8" => hls_media, "low/segment.ts" => hls_transport(audio: false) }
    expect(validate_files(files: files)).to include("audio" => false, "chapters" => [])
  end

  it "rejects mismatched variant durations and segment counts" do
    files = hls_variant_files
    files["high/index.m3u8"] = hls_media(segments: [ [ "segment.ts", "2.4" ] ])
    expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
    files["high/index.m3u8"] = hls_media(segments: [ [ "segment.ts", "1.25" ], [ "segment.ts", "1.25" ] ])
    expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
  end

  it "rejects audio presence changes between variants or within one playlist" do
    files = hls_variant_files.merge("high/segment.ts" => hls_transport(audio: false))
    expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
    files = hls_files.merge("silent.ts" => hls_transport(audio: false),
      "index.m3u8" => hls_media(segments: [ [ "segment.ts", "2.5" ], [ "silent.ts", "2.5" ] ]))
    expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
  end

  it "rejects nested masters and cycles" do
    files = hls_variant_files.merge("low/index.m3u8" => hls_master(paths: [ "child.m3u8" ]))
    expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
    expect { validate_files(files: { "index.m3u8" => hls_master(paths: [ "index.m3u8" ]) }) }.to raise_error(Video::InvalidHls)
  end

  it "rejects undeclared references, unreachable objects and a missing fixed root" do
    expect { validate_files(files: hls_files.except("segment.ts")) }.to raise_error(Video::InvalidHls)
    expect { validate_files(files: hls_files.merge("unused.ts" => hls_transport)) }.to raise_error(Video::InvalidHls)
    expect { validate_files(files: { "other.m3u8" => hls_media }) }.to raise_error(Video::InvalidHls)
  end

  it "validates a single-file fragmented MP4 package whose initialization is a byte range of the media file" do
    expect(validate_files(files: hls_fmp4_files)).to eq("format" => "fmp4", "audio" => nil, "duration" => 2.5, "chapters" => [])
  end

  it "accepts consecutive fragmented MP4 parts with their own initialization, a trailing mfra index and chapters" do
    files = hls_fmp4_files(parts: [ { name: "part-1.mp4" }, { name: "part-2.mp4", init: "init-2.mp4" } ])
    files["part-2.mp4"] += mp4_box("mfra", mp4_box("mfro", "\x00" * 8))
    files["chapters.vtt"] = "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nWhole game\n"
    expect(validate_files(files: files)).to include("duration" => 5.0, "chapters" => [ include("title" => "Whole game") ])
  end

  {
    "a byte range past the end of its file" => ->(files) { files["index.mp4"] = files["index.mp4"].byteslice(0...-1) },
    "bytes no byte range covers" => ->(files) { files["index.mp4"] += mp4_box("free") },
    "overlapping byte ranges" => ->(files) { files["index.m3u8"] = files["index.m3u8"].sub(/(#EXT-X-BYTERANGE:\d+)\n/, "\\1@#{fmp4_init.bytesize}\n") },
    "an initialization without moov" => ->(files) { files["index.mp4"] = files["index.mp4"].sub("moov", "free") },
    "a fragment that does not start with moof" => ->(files) { files["index.mp4"] = files["index.mp4"].sub("moof", "free") },
    "a 64-bit box size" => ->(files) { files["index.mp4"] = [ 1 ].pack("N") + files["index.mp4"].byteslice(4..) },
    "a second part reusing the first part's initialization" => lambda do |files|
      files["index.m3u8"] = files["index.m3u8"].sub("#EXT-X-ENDLIST", %(#EXT-X-MAP:URI="index.mp4",BYTERANGE="#{fmp4_init.bytesize}@0"\n#EXTINF:1,\nindex.mp4\n#EXT-X-ENDLIST))
    end
  }.each do |name, corrupt|
    it "rejects #{name}" do
      files = hls_fmp4_files.tap { |package| instance_exec(package, &corrupt) }
      expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
    end
  end

  it "rejects a fragmented MP4 file declared as MPEG-TS" do
    expect { validate_files(files: hls_fmp4_files, types: { "index.mp4" => "video/mp2t" }) }.to raise_error(Video::InvalidHls)
  end

  [ "/segment.ts", "https://example.test/segment.ts", "../segment.ts", "video/./segment.ts", "video//segment.ts",
    "segment%2ets", "segment.ts?token=private", "segment.ts#fragment", "video\\segment.ts" ].each do |uri|
    it "rejects unsafe reference #{uri.inspect}" do
      files = hls_files.merge("index.m3u8" => hls_media(segments: [ [ uri, "2.5" ] ]))
      expect { validate_files(files: files) }.to raise_error(Video::InvalidHls)
    end
  end

  [ [ "index.m3u8", "text/plain" ], [ "segment.ts", "video/mp4" ], [ "chapters.vtt", "text/plain" ] ].each do |path, type|
    it "rejects the wrong declared MIME for #{path}" do
      files = hls_files.merge("chapters.vtt" => "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nChapter\n")
      expect { validate_files(files: files, types: { path => type }) }.to raise_error(Video::InvalidHls)
    end
  end
end
