require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe PlaythroughPlaylistService do
  include PlaythroughHlsHelpers

  it "accepts CRLF, comments, ignored UTF-8 titles and integer or decimal durations" do
    playlist = hls_media(segments: [ [ "one.ts", "2" ], [ "two.ts", "2.49" ] ], target: 2).sub("#EXTINF", "# A comment\n\n#EXTINF").gsub("\n", "\r\n")
    expect(described_class.parse(bytes: playlist).fetch(:segments).map { |segment| segment.fetch(:duration) }).to eq([ BigDecimal("2"), BigDecimal("2.49") ])
    expect(described_class.parse(bytes: hls_master(paths: [ "one.m3u8", "one.m3u8" ])).fetch(:variants)).to eq([ "one.m3u8", "one.m3u8" ])
    expect(described_class.parse(bytes: hls_master.sub("avc1.42001e,mp4a.40.2", "avc1.42001e, mp4a.40.2")).fetch(:type)).to eq(:master)
  end

  {
    "missing version" => ->(text) { text.sub("#EXT-X-VERSION:3\n", "") },
    "wrong version" => ->(text) { text.sub("VERSION:3", "VERSION:4") },
    "duplicate version" => ->(text) { text.sub("#EXT-X-VERSION:3", "#EXT-X-VERSION:3\n#EXT-X-VERSION:3") },
    "missing header" => ->(text) { text.sub("#EXTM3U\n", "") },
    "BOM" => ->(text) { "\uFEFF#{text}" },
    "invalid UTF-8" => ->(text) { text.b + "\xff".b },
    "control characters" => ->(text) { text.sub("title", "title\t") },
    "non-NFC text" => ->(text) { text.unicode_normalize(:nfd) },
    "bare CR" => ->(text) { text.sub("\n", "\r") },
    "missing EXTINF comma" => ->(text) { text.sub(",Synthetic café title", "") },
    "nonfinite duration" => ->(text) { text.sub("2.5,", "NaN,") },
    "zero duration" => ->(text) { text.sub("2.5,", "0,") },
    "missing EXTINF" => ->(text) { text.sub("#EXTINF:2.5,Synthetic café title\n", "") },
    "duplicate EXTINF" => ->(text) { text.sub("#EXTINF", "#EXTINF:1,\n#EXTINF") },
    "zero target" => ->(text) { text.sub("TARGETDURATION:3", "TARGETDURATION:0") },
    "target overflow" => ->(text) { text.sub("TARGETDURATION:3", "TARGETDURATION:18446744073709551616") },
    "rounding half up" => ->(text) { text.sub("TARGETDURATION:3", "TARGETDURATION:2") },
    "duplicate target" => ->(text) { text.sub("#EXT-X-TARGETDURATION:3", "#EXT-X-TARGETDURATION:3\n#EXT-X-TARGETDURATION:3") },
    "non-VOD media" => ->(text) { text.sub("TYPE:VOD", "TYPE:EVENT") },
    "missing ENDLIST" => ->(text) { text.sub("#EXT-X-ENDLIST\n", "") },
    "nonterminal ENDLIST" => ->(text) { text + "#EXTINF:1,\nextra.ts\n" },
    "nonzero sequence" => ->(text) { text.sub("SEQUENCE:0", "SEQUENCE:1") },
    "late sequence" => ->(text) { text.sub("#EXT-X-MEDIA-SEQUENCE:0\n", "").sub("#EXT-X-ENDLIST", "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-ENDLIST") },
    "unsupported tag" => ->(text) { text.sub("#EXTINF", "#EXT-X-KEY:METHOD=NONE\n#EXTINF") },
    "mixed master/media" => ->(text) { text.sub("#EXTINF", "#EXT-X-STREAM-INF:BANDWIDTH=100\nother.m3u8\n#EXTINF") }
  }.each do |name, corrupt|
    it "rejects #{name}" do
      expect { described_class.parse(bytes: corrupt.call(hls_media)) }.to raise_error(Playthrough::InvalidHls, "invalid_hls")
    end
  end

  [ "", "BANDWIDTH=0", "BANDWIDTH=18446744073709551616", "BANDWIDTH=1,BANDWIDTH=2",
    'BANDWIDTH="1"', "BANDWIDTH=1, AVERAGE-BANDWIDTH=1", "BANDWIDTH=1,AVERAGE-BANDWIDTH=0", 'BANDWIDTH=1,CODECS="avc1..42001e"',
    "BANDWIDTH=1,CODECS=avc1.42001e", 'BANDWIDTH=1,CODECS=""', "BANDWIDTH=1,RESOLUTION=0x240",
    'BANDWIDTH=1,AUDIO="audio"', "BANDWIDTH=1," ].each do |attributes|
    it "rejects malformed or unsupported stream attributes #{attributes.inspect}" do
      text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:#{attributes}\nmedia.m3u8\n"
      expect { described_class.parse(bytes: text) }.to raise_error(Playthrough::InvalidHls)
    end
  end
end
