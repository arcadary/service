require "rails_helper"
require_relative "../support/screenshot_helpers"

RSpec.describe ScreenshotPngService do
  include ScreenshotHelpers

  def decode(bytes, system: "gb")
    described_class.decode(io: StringIO.new(bytes), system: system)
  end

  it "keeps only pixels and measures and hashes the stored PNG" do
    bytes = png(chunks: [ png_chunk("tEXt", "Comment\0private metadata") ])
    result = decode(bytes)
    expect(result.slice(:width, :height)).to eq(width: 2, height: 2)
    expect(result.fetch(:bytes)).not_to include("private metadata")
    expect(result.fetch(:sha256)).to eq(Digest::SHA256.hexdigest(result.fetch(:bytes)))
    image = Vips::Image.pngload_buffer(result.fetch(:bytes))
    expect(image.write_to_memory).to eq("\x12\x34\x56\xff".b * 4)
    expect(decode(result.fetch(:bytes))).to eq(result)
  end

  ScreenshotPngService::LIMITS.each do |system, (width, height)|
    it "accepts the fixed #{system} ceilings and rejects either dimension beyond them before decoding" do
      expect(decode(png(width: width, height: height), system: system).slice(:width, :height)).to eq(width: width, height: height)
      expect(Vips::Image).not_to receive(:pngload_buffer)
      expect { decode(png(width: width + 1, height: 1), system: system) }.to raise_error(Screenshot::InvalidImage)
      expect { decode(png(width: 1, height: height + 1), system: system) }.to raise_error(Screenshot::InvalidImage)
    end
  end

  it "bounds input reads and accepts exactly the byte cap" do
    bytes = png
    padding = "Comment\0" + "a" * (described_class::MAX_BYTES - bytes.bytesize - 12 - 8)
    at_limit = png(chunks: [ png_chunk("tEXt", padding) ])
    expect(at_limit.bytesize).to eq(8_388_608)
    expect(decode(at_limit).fetch(:width)).to eq(2)
    io = StringIO.new(at_limit + "a")
    expect(io).to receive(:read).with(8_388_609).and_call_original
    expect { described_class.decode(io: io, system: "gb") }.to raise_error(Screenshot::TooLarge)
  end

  it "rejects malformed, animated and truncated PNGs, including corrupt compressed pixels" do
    broken_pixels = ScreenshotPngService::SIGNATURE + png_chunk("IHDR", [ 2, 2, 8, 6, 0, 0, 0 ].pack("NNC5")) + png_chunk("IDAT", "broken") + png_chunk("IEND", "")
    [ "not a PNG", png.byteslice(0...-1), png(chunks: [ png_chunk("acTL", [ 1, 0 ].pack("NN")) ]), broken_pixels ].each do |bytes|
      expect { decode(bytes) }.to raise_error(Screenshot::InvalidImage)
    end
    zero_dimensions = png
    zero_dimensions[8, 25] = png_chunk("IHDR", [ 0, 2, 8, 6, 0, 0, 0 ].pack("NNC5"))
    expect { decode(zero_dimensions) }.to raise_error(Screenshot::InvalidImage)
  end

  it "rejects PNGs libvips warns about without writing to stderr" do
    header = png_chunk("IHDR", [ 2, 2, 8, 6, 0, 0, 0 ].pack("NNC5"))
    rows = ("\0".b + "\x12\x34\x56\xff".b * 2) * 2
    compressed = Zlib.deflate(rows)
    corrupt = [ Zlib.deflate(rows.byteslice(0, 5)), compressed.byteslice(0...-6), compressed.byteslice(0...-4) + "\0\0\0\0".b ].map do |data|
      ScreenshotPngService::SIGNATURE + header + png_chunk("IDAT", data) + png_chunk("IEND", "")
    end

    expect do
      corrupt.each { |bytes| expect { decode(bytes) }.to raise_error(Screenshot::InvalidImage) }
    end.not_to output.to_stderr_from_any_process
  end
end
