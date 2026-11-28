module PlaythroughHelpers
  def playthrough_declaration(release:, bytes: "synthetic segment", retry_key: SecureRandom.uuid)
    {
      "retry_key" => retry_key, "release_id" => release.public_id, "source_sha1" => release.sha1,
      "capture" => { "tool" => "synthetic-capture", "version" => "1", "captured_at" => "2026-11-28T08:00:00Z" },
      "manifest" => [ { "path" => "video/segment.ts", "byte_size" => bytes.bytesize,
        "sha256" => Digest::SHA256.hexdigest(bytes), "content_type" => "video/mp2t" } ]
    }
  end

  def declare_playthrough(input: declaration)
    PlaythroughStagingService.create(declaration: input, verifier: "synthetic-admin")
  end

  def receive_playthrough(stage:, bytes: "synthetic segment", object: stage.objects.first, content_type: object.content_type)
    PlaythroughTransferService.receive(staging_id: stage.public_id, object_id: object.public_id,
      io: StringIO.new(bytes), content_type: content_type)
  end

  def playthrough_verification(source:, payload:)
    { "source_sha1" => source, "payload_sha1" => payload, "relationship" => "trailing_padding", "removed_bytes" => 127,
      "method" => "Offline byte comparison after removing trailing padding", "result" => "success", "verifier" => "synthetic-admin",
      "verified_at" => "2026-11-28T08:00:00Z", "evidence" => "Source #{source} matches payload #{payload} after removing 127 bytes." }
  end
end
