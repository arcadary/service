require "zlib"

module ScreenshotHelpers
  def png_chunk(type, payload)
    [ payload.bytesize ].pack("N") + type + payload + [ Zlib.crc32(type + payload) ].pack("N")
  end

  def png(width: 2, height: 2, pixel: "\x12\x34\x56\xff".b, chunks: [])
    header = [ width, height, 8, 6, 0, 0, 0 ].pack("NNC5")
    rows = ("\0".b + pixel * width) * height
    ScreenshotPngService::SIGNATURE + png_chunk("IHDR", header) + chunks.join + png_chunk("IDAT", Zlib.deflate(rows)) + png_chunk("IEND", "")
  end

  def upload_screenshot(release:, kind: "gameplay", bytes: png)
    ScreenshotService.create(release: release, kind: kind, io: StringIO.new(bytes), content_type: "image/png")
  end
end
