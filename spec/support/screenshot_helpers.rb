require "zlib"
require_relative "upload_helpers"

module ScreenshotHelpers
  include UploadHelpers

  def png_chunk(type, payload)
    [ payload.bytesize ].pack("N") + type + payload + [ Zlib.crc32(type + payload) ].pack("N")
  end

  def png(width: 2, height: 2, pixel: "\x12\x34\x56\xff".b, chunks: [])
    header = [ width, height, 8, 6, 0, 0, 0 ].pack("NNC5")
    rows = ("\0".b + pixel * width) * height
    ScreenshotPngService::SIGNATURE + png_chunk("IHDR", header) + chunks.join + png_chunk("IDAT", Zlib.deflate(rows)) + png_chunk("IEND", "")
  end

  def red_png
    png(pixel: "\xff\0\0\xff".b)
  end

  def green_png
    png(pixel: "\0\xff\0\xff".b)
  end

  def confirmed_screenshot(bytes: png)
    confirmed_upload(kind: "screenshot", files: { "screenshot.png" => [ bytes, "image/png" ] })
  end

  def upload_screenshot(release:, kind: "gameplay", bytes: png)
    ScreenshotService.create(upload_id: confirmed_screenshot(bytes: bytes).public_id, release_id: release.public_id, kind: kind)
  end
end
