module VideoHlsHelpers
  def hls_media(segments: [ [ "segment.ts", "2.5" ] ], target: 3)
    [ "#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:#{target}", "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-MEDIA-SEQUENCE:0", *segments.flat_map { |path, duration| [ "#EXTINF:#{duration},Synthetic café title", path ] },
      "#EXT-X-ENDLIST", "" ].join("\n")
  end

  def hls_master(paths: [ "low/index.m3u8", "high/index.m3u8" ])
    [ "#EXTM3U", "#EXT-X-VERSION:3", *paths.flat_map { |path| [ '#EXT-X-STREAM-INF:BANDWIDTH=100000,AVERAGE-BANDWIDTH=90000,CODECS="avc1.42001e,mp4a.40.2",RESOLUTION=256x240', path ] }, "" ].join("\n")
  end

  def hls_files(audio: true)
    { "index.m3u8" => hls_media, "segment.ts" => hls_transport(audio: audio) }
  end

  def hls_variant_files
    { "index.m3u8" => hls_master, "low/index.m3u8" => hls_media,
      "high/index.m3u8" => hls_media(segments: [ [ "segment.ts", "2.500" ] ]),
      "low/segment.ts" => hls_transport, "high/segment.ts" => hls_transport,
      "chapters.vtt" => "\uFEFFWEBVTT\n\n00:00:00.000 --> 00:00:02.500\nFirst chapter\n" }
  end

  def hls_content_type(name)
    { ".m3u8" => "application/vnd.apple.mpegurl", ".ts" => "video/mp2t", ".mp4" => "video/mp4", ".m4s" => "video/mp4", ".vtt" => "text/vtt" }.fetch(File.extname(name))
  end

  def mp4_box(type, payload = "")
    [ 8 + payload.bytesize, type ].pack("Na4") + payload.b
  end

  def fmp4_init
    mp4_box("ftyp", "iso6\x00\x00\x00\x00iso6cmfc") + mp4_box("moov", mp4_box("mvhd", "\x00" * 100))
  end

  def fmp4_fragment
    mp4_box("moof", mp4_box("mfhd", "\x00" * 8)) + mp4_box("mdat", "synthetic sample")
  end

  def fmp4_part(name:, init: nil)
    fragments = [ fmp4_fragment, fmp4_fragment ]
    start = init ? 0 : fmp4_init.bytesize
    map = init ? %(#EXT-X-MAP:URI="#{init}") : %(#EXT-X-MAP:URI="#{name}",BYTERANGE="#{fmp4_init.bytesize}@0")
    lines = [ map, "#EXTINF:1.500000,", "#EXT-X-BYTERANGE:#{fragments.first.bytesize}@#{start}", name,
              "#EXTINF:1.0,", "#EXT-X-BYTERANGE:#{fragments.last.bytesize}", name ]
    files = init ? { init => fmp4_init, name => fragments.join } : { name => fmp4_init + fragments.join }
    [ lines, files ]
  end

  def hls_fmp4_files(parts: [ { name: "index.mp4" } ])
    lines = []
    files = {}
    parts.each_with_index do |part, index|
      part_lines, part_files = fmp4_part(**part)
      lines.push(*("#EXT-X-DISCONTINUITY" if index.positive?), *part_lines)
      files.merge!(part_files)
    end
    playlist = [ "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0", "#EXT-X-PLAYLIST-TYPE:VOD",
                 *lines, "#EXT-X-ENDLIST", "" ].join("\n")
    { "index.m3u8" => playlist }.merge(files)
  end

  def hls_transport(audio: true, streams: nil, programs: [ [ 1, 0x100 ] ])
    streams ||= [ [ 0x1b, 0x101 ], *([ [ 0x0f, 0x102 ] ] if audio) ]
    pat_data = [ 1, 0xc1, 0, 0 ].pack("nC3") + programs.map { |number, pid| [ number, 0xe000 | pid ].pack("n2") }.join
    pmt_data = [ 1, 0xc1, 0, 0, 0xe101, 0xf000 ].pack("nC3n2") + streams.map { |type, pid| [ type, 0xe000 | pid, 0xf000 ].pack("Cnn") }.join
    pat = hls_psi(table: 0, data: pat_data)
    pmt = hls_psi(table: 2, data: pmt_data)
    hls_packet(pid: 0, payload: "\x00".b + pat, start: true) + hls_packet(pid: 0x100, payload: "\x00".b + pmt, start: true) +
      streams.map { |_, pid| hls_packet(pid: pid, payload: "\x00\x00\x01\xe0synthetic payload".b, start: true) }.join
  end

  def hls_packet(pid:, payload:, start: false, counter: 0)
    [ 0x47, (start ? 0x40 : 0) | (pid >> 8), pid & 255, 0x10 | counter ].pack("C4") + payload.ljust(184, "\xff".b)
  end

  def hls_psi(table:, data:, section_flags: 0xb000)
    section = [ table, section_flags | (data.bytesize + 4) ].pack("Cn") + data
    crc = 0xffffffff
    section.each_byte do |byte|
      crc ^= byte << 24
      8.times { crc = ((crc << 1) ^ (crc[31] == 1 ? 0x04c11db7 : 0)) & 0xffffffff }
    end
    section + [ crc ].pack("N")
  end
end
