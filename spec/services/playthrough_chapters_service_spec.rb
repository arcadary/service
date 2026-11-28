require "rails_helper"

RSpec.describe PlaythroughChaptersService do
  let(:chapter) { "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nFirst chapter\n" }

  it "accepts chronological adjacent cues, UTF-8 titles and CRLF with an initial BOM" do
    bytes = "\uFEFF#{chapter}\n00:00:01.000 --> 00:00:02.500\nCafé\n".gsub("\n", "\r\n")
    expect(described_class.parse(bytes: bytes, duration: BigDecimal("2.5")).last).to eq("start" => "00:00:01.000", "end" => "00:00:02.500", "title" => "Café")
  end

  {
    "header text" => ->(text) { text.sub("WEBVTT", "WEBVTT chapters") },
    "missing blank header line" => ->(text) { text.sub("WEBVTT\n\n", "WEBVTT\n") },
    "invalid UTF-8" => ->(text) { text.b + "\xff".b },
    "cue identifier" => ->(text) { text.sub("00:00:00.000", "chapter-1\n00:00:00.000") },
    "cue settings" => ->(text) { text.sub("00:00:01.000\n", "00:00:01.000 align:start\n") },
    "markup" => ->(text) { text.sub("First chapter", "<b>First chapter</b>") },
    "entity" => ->(text) { text.sub("First chapter", "First &amp; last") },
    "arrow in title" => ->(text) { text.sub("First chapter", "First --> last") },
    "blank title" => ->(text) { text.sub("First chapter", "  ") },
    "multiline title" => ->(text) { text.sub("First chapter", "First\nchapter") },
    "NOTE block" => ->(text) { text.sub("\n\n", "\n\nNOTE private note\n\n") },
    "STYLE block" => ->(text) { text.sub("\n\n", "\n\nSTYLE\n::cue { color: red }\n\n") },
    "REGION block" => ->(text) { text.sub("\n\n", "\n\nREGION\nid:one\n\n") },
    "bad timestamp" => ->(text) { text.sub("00:00:01.000", "00:60:01.000") },
    "zero length" => ->(text) { text.sub("00:00:01.000", "00:00:00.000") },
    "beyond timeline" => ->(text) { text.sub("00:00:01.000", "00:00:03.000") },
    "overlap" => ->(text) { text + "\n00:00:00.999 --> 00:00:02.000\nNext\n" },
    "no separator" => ->(text) { text + "00:00:01.000 --> 00:00:02.000\nNext\n" },
    "no cues" => ->(text) { "WEBVTT\n\n" }
  }.each do |name, corrupt|
    it "rejects #{name}" do
      expect { described_class.parse(bytes: corrupt.call(chapter), duration: BigDecimal("2.5")) }.to raise_error(PlaythroughStage::InvalidHls)
    end
  end

  it "rejects 257 cues within an otherwise valid timeline" do
    cues = 257.times.map { |index| "00:00:#{format('%02d', index / 10)}.#{index % 10}00 --> 00:00:#{format('%02d', (index + 1) / 10)}.#{(index + 1) % 10}00\nChapter\n" }
    expect { described_class.parse(bytes: "WEBVTT\n\n#{cues.join("\n")}", duration: BigDecimal("30")) }.to raise_error(PlaythroughStage::InvalidHls)
  end
end
