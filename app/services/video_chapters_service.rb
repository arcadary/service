class VideoChaptersService
  TIMESTAMP = "[0-9]{2}:[0-5][0-9]:[0-5][0-9]\\.[0-9]{3}"
  TIMING = /\A(#{TIMESTAMP}) --> (#{TIMESTAMP})\z/

  def self.parse(bytes:, duration:)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    invalid! unless text.valid_encoding?
    text = text.delete_prefix("\uFEFF").gsub(/\r\n?/, "\n")
    invalid! if text.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\ufeff]/)
    lines = text.split("\n", -1)
    invalid! unless lines.shift == "WEBVTT" && lines.shift == ""
    cues = []
    previous_end = 0
    until lines.empty?
      next if lines.first == "" && lines.shift
      timing = TIMING.match(lines.shift)
      title = lines.shift
      invalid! unless timing && title.present? && !title.match?(/<|&|-->/) && (lines.empty? || lines.first == "")
      start_time = seconds(timestamp: timing[1])
      end_time = seconds(timestamp: timing[2])
      invalid! unless start_time >= previous_end && start_time < end_time && end_time <= duration
      cues << { "start" => start_time.to_f, "end" => end_time.to_f, "title" => title }
      invalid! if cues.length > 256
      previous_end = end_time
    end
    invalid! if cues.empty?
    cues
  end

  def self.seconds(timestamp:)
    hours, minutes, seconds = timestamp.split(":")
    hours.to_i * 3600 + minutes.to_i * 60 + BigDecimal(seconds)
  end
  private_class_method :seconds

  def self.invalid!
    raise Video::InvalidHls, "invalid_hls"
  end
  private_class_method :invalid!
end
