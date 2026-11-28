class PlaythroughTransportService
  def self.validate(bytes:)
    new.validate(bytes: bytes)
  end

  def initialize
    @buffers = {}
    @continuity = {}
    @tables = {}
    @payloads = Set.new
  end

  def validate(bytes:)
    invalid! unless bytes.bytesize.positive? && (bytes.bytesize % 188).zero?
    (0...bytes.bytesize).step(188) { |offset| packet(bytes: bytes.byteslice(offset, 188)) }
    invalid! unless @streams && @buffers.values.all?(&:empty?) && @streams.keys.to_set == @payloads
    @streams.value?(0x0f)
  end

  private

  def packet(bytes:)
    sync, flags, low_pid, control = bytes.byteslice(0, 4).unpack("C4")
    invalid! unless sync == 0x47 && (flags & 0x80).zero? && (control & 0xc0).zero?
    pid = ((flags & 0x1f) << 8) | low_pid
    adaptation_control = (control >> 4) & 3
    invalid! if adaptation_control.zero?
    offset = 4
    if (adaptation_control & 2).positive?
      length = bytes.getbyte(offset)
      invalid! if length > 183 || (adaptation_control == 2 && length != 183) || (adaptation_control == 3 && length > 182)
      adaptation(bytes: bytes.byteslice(5, length)) if length.positive?
      offset += 1 + length
    end
    return if pid == 0x1fff || pid.between?(0x0010, 0x001f)
    invalid! unless pid.zero? || pid == @pmt_pid || pid == @pcr_pid || @streams&.key?(pid)
    if pid.zero? || pid == @pmt_pid
      return if (adaptation_control & 1).zero?
      counter = control & 0x0f
      invalid! if @buffers[pid].present? && counter != ((@continuity.fetch(pid) + 1) & 15)
      @continuity[pid] = counter
      psi(pid: pid, payload: bytes.byteslice(offset..), start: (flags & 0x40).positive?)
    else
      invalid! unless @streams
      invalid! if pid == @pcr_pid && !@streams.key?(pid) && (adaptation_control & 1).positive?
      @payloads.add(pid) if (adaptation_control & 1).positive? && offset < 188
    end
  end

  def adaptation(bytes:)
    flags = bytes.getbyte(0)
    offset = 1
    offset += 6 if (flags & 0x10).positive?
    offset += 6 if (flags & 0x08).positive?
    offset += 1 if (flags & 0x04).positive?
    if (flags & 0x02).positive?
      invalid! unless offset < bytes.bytesize
      offset += 1 + bytes.getbyte(offset)
    end
    if (flags & 0x01).positive?
      invalid! unless offset < bytes.bytesize
      length = bytes.getbyte(offset)
      extension = bytes.byteslice(offset + 1, length)
      invalid! unless extension && extension.bytesize == length
      adaptation_extension(bytes: extension) if length.positive?
      offset += 1 + length
    end
    invalid! unless offset <= bytes.bytesize && bytes.byteslice(offset..).bytes.all? { |byte| byte == 0xff }
  end

  def adaptation_extension(bytes:)
    flags = bytes.getbyte(0)
    length = 1
    length += 2 if (flags & 0x80).positive?
    length += 3 if (flags & 0x40).positive?
    length += 5 if (flags & 0x20).positive?
    invalid! if length > bytes.bytesize
  end

  def psi(pid:, payload:, start:)
    buffer = @buffers[pid] ||= +"".b
    if start
      pointer = payload.getbyte(0)
      invalid! unless pointer && pointer < payload.bytesize
      prefix = payload.byteslice(1, pointer)
      if buffer.empty?
        invalid! unless prefix.bytes.all? { |byte| byte == 0xff }
      else
        buffer << prefix
        sections(pid: pid, buffer: buffer)
        invalid! unless buffer.empty?
      end
      buffer << payload.byteslice(1 + pointer..)
    else
      invalid! if buffer.empty?
      buffer << payload
    end
    sections(pid: pid, buffer: buffer)
  end

  def sections(pid:, buffer:)
    until buffer.empty?
      if buffer.getbyte(0) == 0xff
        invalid! unless buffer.bytes.all? { |byte| byte == 0xff }
        buffer.clear
        break
      end
      break if buffer.bytesize < 3
      high, low = buffer.byteslice(1, 2).unpack("C2")
      length = ((high & 15) << 8) | low
      invalid! unless (high & 0xf0) == 0xb0 && length.between?(9, 1021)
      break if buffer.bytesize < length + 3
      section = buffer.slice!(0, length + 3)
      invalid! unless crc(bytes: section).zero? && (section.getbyte(5) & 0xc1) == 0xc1 && section.getbyte(6) <= section.getbyte(7)
      key = [ pid, section.getbyte(6) ]
      invalid! if @tables.key?(key) && @tables.fetch(key) != section
      pid.zero? ? pat(section: section) : pmt(section: section)
      @tables[key] = section
    end
  end

  def pat(section:)
    invalid! unless section.getbyte(0).zero? && ((section.bytesize - 12) % 4).zero?
    @pat_sections ||= {}
    if @pat_sections.any?
      invalid! unless @pat_sections.values.first.byteslice(3, 3) == section.byteslice(3, 3) && @pat_sections.values.first.getbyte(7) == section.getbyte(7)
    end
    @pat_sections[section.getbyte(6)] = section
    return unless @pat_sections.size == section.getbyte(7) + 1
    programs = []
    @pat_sections.each_value do |part|
      part.byteslice(8, part.bytesize - 12).unpack("n*").each_slice(2) do |number, pid|
        invalid! unless (pid & 0xe000) == 0xe000
        programs << [ number, pid & 0x1fff ] unless number.zero?
      end
    end
    invalid! unless programs.length == 1 && programs.first.last.between?(0x20, 0x1ffe)
    @program, @pmt_pid = programs.first
  end

  def pmt(section:)
    invalid! unless @program && section.getbyte(0) == 2 && section.byteslice(3, 2).unpack1("n") == @program && section.bytesize >= 21 && section.getbyte(6).zero? && section.getbyte(7).zero?
    pcr, info = section.byteslice(8, 4).unpack("n2")
    invalid! unless (pcr & 0xe000) == 0xe000 && (info & 0xf000) == 0xf000
    ending = section.bytesize - 4
    offset = 12 + (info & 0x0fff)
    invalid! if offset > ending
    descriptors(bytes: section.byteslice(12, info & 0x0fff))
    streams = {}
    while offset < ending
      invalid! if offset + 5 > ending
      type, pid, length = section.byteslice(offset, 5).unpack("Cnn")
      invalid! unless (pid & 0xe000) == 0xe000 && (length & 0xf000) == 0xf000
      pid &= 0x1fff
      length &= 0x0fff
      invalid! unless pid.between?(0x20, 0x1ffe) && pid != @pmt_pid && !streams.key?(pid) && offset + 5 + length <= ending
      descriptors(bytes: section.byteslice(offset + 5, length))
      streams[pid] = type
      offset += 5 + length
    end
    types = streams.values.sort
    @pcr_pid = pcr & 0x1fff
    invalid! unless [ [ 0x1b ], [ 0x0f, 0x1b ] ].include?(types) && @pcr_pid.between?(0x20, 0x1ffe) && @pcr_pid != @pmt_pid
    @streams = streams
  end

  def descriptors(bytes:)
    offset = 0
    while offset < bytes.bytesize
      invalid! if offset + 2 > bytes.bytesize
      offset += 2 + bytes.getbyte(offset + 1)
      invalid! if offset > bytes.bytesize
    end
  end

  def crc(bytes:)
    value = 0xffffffff
    bytes.each_byte do |byte|
      value ^= byte << 24
      8.times { value = (value << 1) ^ ((value & 0x80000000).zero? ? 0 : 0x04c11db7) }
      value &= 0xffffffff
    end
    value
  end

  def invalid!
    raise Playthrough::InvalidHls, "invalid_hls"
  end
end
