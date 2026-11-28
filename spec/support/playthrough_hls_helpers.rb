require_relative "playthrough_helpers"

module PlaythroughHlsHelpers
  include PlaythroughHelpers

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

  def declare_hls(release:, files:, types: {})
    input = playthrough_declaration(release: release)
    input["manifest"] = files.map do |path, bytes|
      { "path" => path, "byte_size" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
        "content_type" => types.fetch(path) { { ".m3u8" => "application/vnd.apple.mpegurl", ".ts" => "video/mp2t", ".vtt" => "text/vtt" }.fetch(File.extname(path)) } }
    end
    declare_playthrough(input: input)
  end

  def receive_hls(stage:, files:)
    stage.objects.each { |object| receive_playthrough(stage: stage, object: object, bytes: files.fetch(object.path)) }
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

  def hls_psi(table:, data:)
    section = [ table, 0xb000 | (data.bytesize + 4) ].pack("Cn") + data
    crc = 0xffffffff
    section.each_byte do |byte|
      crc ^= byte << 24
      8.times { crc = ((crc << 1) ^ (crc[31] == 1 ? 0x04c11db7 : 0)) & 0xffffffff }
    end
    section + [ crc ].pack("N")
  end
end
