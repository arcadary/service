require "rails_helper"
require_relative "../support/playthrough_hls_helpers"

RSpec.describe PlaythroughTransportService do
  include PlaythroughHlsHelpers

  it "classifies H.264/AAC and silent H.264 from PMTs" do
    expect(described_class.validate(bytes: hls_transport)).to be(true)
    expect(described_class.validate(bytes: hls_transport(audio: false))).to be(false)
  end

  it "accepts a DVB service description table before the PAT" do
    data = [ 1, 0xc1, 0, 0, 1, 0xff, 1, 0xfc, 0x8000 ].pack("nC3nCnCn")
    section = hls_psi(table: 0x42, data: data, section_flags: 0xf000)
    sdt = hls_packet(pid: 0x11, payload: "\x00".b + section, start: true)

    expect(described_class.validate(bytes: sdt + hls_transport)).to be(true)
  end

  it "assembles PSI across packet boundaries with adaptation stuffing" do
    bytes = hls_transport
    pmt = bytes.byteslice(188, 188).byteslice(5, 26)
    first = [ 0x47, 0x41, 0, 0x30, 170, 0 ].pack("C6") + "\xff".b * 169 + "\x00".b + pmt.byteslice(0, 12)
    second = hls_packet(pid: 0x100, payload: pmt.byteslice(12..), counter: 1)
    expect(described_class.validate(bytes: bytes.byteslice(0, 188) + first + second + bytes.byteslice(376..))).to be(true)
  end

  {
    "empty transport" => ->(bytes) { "".b },
    "truncated packet" => ->(bytes) { bytes.byteslice(0...-1) },
    "bad sync byte" => ->(bytes) { bytes.tap { |data| data.setbyte(188, 0) } },
    "transport error" => ->(bytes) { bytes.tap { |data| data.setbyte(1, 0xc0) } },
    "scrambled packet" => ->(bytes) { bytes.tap { |data| data.setbyte(3, 0x90) } },
    "reserved adaptation control" => ->(bytes) { bytes.tap { |data| data.setbyte(3, 0) } },
    "adaptation overflow" => ->(bytes) { bytes.tap { |data| data.setbyte(3, 0x30); data.setbyte(4, 183) } },
    "truncated PCR" => ->(bytes) { bytes.tap { |data| data.setbyte(3, 0x30); data.setbyte(4, 1); data.setbyte(5, 0x10) } },
    "PSI pointer overflow" => ->(bytes) { bytes.tap { |data| data.setbyte(4, 184) } },
    "PSI section overflow" => ->(bytes) { bytes.tap { |data| data.setbyte(6, 0xbf) } },
    "PAT CRC error" => ->(bytes) { bytes.tap { |data| data.setbyte(20, data.getbyte(20) ^ 1) } },
    "PMT CRC error" => ->(bytes) { bytes.tap { |data| data.setbyte(213, data.getbyte(213) ^ 1) } },
    "PMT before PAT" => ->(bytes) { bytes.byteslice(188, 188) + bytes.byteslice(0, 188) + bytes.byteslice(376..) },
    "elementary stream before PMT" => ->(bytes) { bytes.byteslice(0, 188) + bytes.byteslice(376, 188) + bytes.byteslice(188, 188) + bytes.byteslice(564..) },
    "undeclared elementary stream" => ->(bytes) { bytes.tap { |data| data.setbyte(378, 0x03) } },
    "conditional-access PID" => ->(bytes) { bytes.tap { |data| data.setbyte(2, 1) } },
    "absent declared audio payload" => ->(bytes) { bytes.byteslice(0, 564) }
  }.each do |name, corrupt|
    it "rejects #{name}" do
      expect { described_class.validate(bytes: corrupt.call(hls_transport)) }.to raise_error(Playthrough::InvalidHls)
    end
  end

  [ [ [ 0x24, 0x101 ] ], [ [ 0x1b, 0x101 ], [ 0x03, 0x102 ] ],
    [ [ 0x1b, 0x101 ], [ 0x1b, 0x102 ] ], [ [ 0x0f, 0x102 ] ],
    [ [ 0x1b, 0x101 ], [ 0x0f, 0x102 ], [ 0x0f, 0x103 ] ] ].each do |streams|
    it "rejects unsupported stream types or counts #{streams.inspect}" do
      expect { described_class.validate(bytes: hls_transport(streams: streams)) }.to raise_error(Playthrough::InvalidHls)
    end
  end

  it "rejects a second program even with a valid PAT CRC" do
    expect { described_class.validate(bytes: hls_transport(programs: [ [ 1, 0x100 ], [ 2, 0x200 ] ])) }.to raise_error(Playthrough::InvalidHls)
  end

  it "rejects malformed PMT descriptor lengths even with a valid CRC" do
    data = [ 1, 0xc1, 0, 0, 0xe101, 0xf003, 0x52, 8, 0 ].pack("nC3n2C3") + [ 0x1b, 0xe101, 0xf000 ].pack("Cnn")
    bytes = hls_transport(audio: false)
    bytes[188, 188] = hls_packet(pid: 0x100, payload: "\x00".b + hls_psi(table: 2, data: data), start: true)
    expect { described_class.validate(bytes: bytes) }.to raise_error(Playthrough::InvalidHls)
  end
end
