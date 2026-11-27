require "zlib"

class ScreenshotPngService
  MAX_BYTES = 8_388_608
  DECODE_LOCK = Mutex.new
  LIMITS = {
    "nes" => [ 1024, 960 ], "snes" => [ 2048, 1912 ], "gb" => [ 640, 576 ], "gbc" => [ 640, 576 ],
    "megadrive" => [ 1280, 1920 ], "pcengine" => [ 2048, 960 ], "atari2600" => [ 640, 768 ], "c64" => [ 1536, 1088 ]
  }.freeze
  SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  def self.decode(io:, system:)
    bytes = io.read(MAX_BYTES + 1).to_s.b
    raise Screenshot::TooLarge if bytes.bytesize > MAX_BYTES

    new(bytes: bytes, system: system).decode
  end

  def initialize(bytes:, system:)
    @bytes, @system = bytes, system
  end

  def decode
    validate_chunks
    require "vips"
    DECODE_LOCK.synchronize { reencode_pixels }
  end

  private
    def reencode_pixels
      Vips.vips_error_clear
      image = Vips::Image.pngload_buffer(@bytes, access: :sequential, fail_on: :warning)
      memory = image.write_to_memory
      raise Vips::Error unless Vips.vips_error_buffer.empty?

      pixels = Vips::Image.new_from_memory(memory, image.width, image.height, image.bands, image.format).copy(interpretation: image.interpretation)
      png = pixels.pngsave_buffer(strip: true)
      { bytes: png, width: pixels.width, height: pixels.height, sha256: Digest::SHA256.hexdigest(png) }
    rescue Vips::Error
      raise Screenshot::InvalidImage
    ensure
      Vips.vips_error_clear
    end
    def validate_chunks
      raise Screenshot::InvalidImage unless @bytes.start_with?(SIGNATURE)

      offset = SIGNATURE.bytesize
      header = false
      data = false
      while offset < @bytes.bytesize
        length, type = @bytes.byteslice(offset, 8)&.unpack("Na4")
        raise Screenshot::InvalidImage unless length && offset + length + 12 <= @bytes.bytesize

        payload = @bytes.byteslice(offset + 8, length)
        crc = @bytes.byteslice(offset + 8 + length, 4).unpack1("N")
        raise Screenshot::InvalidImage unless Zlib.crc32(type + payload) == crc
        raise Screenshot::InvalidImage if %w[acTL fcTL fdAT].include?(type)
        raise Screenshot::InvalidImage if !header && type != "IHDR"

        if type == "IHDR"
          raise Screenshot::InvalidImage if header || length != 13

          validate_dimensions(payload.unpack("NN"))
          header = true
        end
        data = true if type == "IDAT"
        offset += length + 12
        if type == "IEND"
          raise Screenshot::InvalidImage unless length.zero? && data && offset == @bytes.bytesize

          return
        end
      end
      raise Screenshot::InvalidImage
    end

    def validate_dimensions(dimensions)
      dimensions.zip(LIMITS.fetch(@system)).each do |value, maximum|
        raise Screenshot::InvalidImage unless value.positive? && value <= maximum
      end
    end
end
