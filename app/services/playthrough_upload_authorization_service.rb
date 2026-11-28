class PlaythroughUploadAuthorizationService
  LIFETIME = 900

  def self.issue(stage:)
    expires_at = (Time.current + LIFETIME).iso8601(9)
    payload = binding(stage: stage).merge("expires_at" => expires_at, "nonce" => SecureRandom.hex(16))
    { capability: verifier.generate(payload, purpose: "playthrough-upload"), expires_at: expires_at }
  end

  def self.authorize!(capability:, staging_id:, object_id:)
    raise PlaythroughStage::UploadNotAuthorized unless capability.is_a?(String) && capability.bytesize <= 4096

    payload = verifier.verified(capability, purpose: "playthrough-upload")
    unless payload.is_a?(Hash) && payload["expires_at"].is_a?(String) && Time.current < Time.iso8601(payload["expires_at"])
      raise PlaythroughStage::UploadNotAuthorized
    end

    stage = PlaythroughStage.includes(:release).find_by(public_id: staging_id)
    unless stage && payload.slice(*binding(stage: stage).keys) == binding(stage: stage) && stage.objects.exists?(public_id: object_id)
      raise PlaythroughStage::UploadNotAuthorized
    end
    stage
  end

  def self.binding(stage:)
    { "staging_id" => stage.public_id, "release_id" => stage.release.public_id,
      "package_sha256" => stage.package_sha256, "declaration_sha256" => stage.declaration_sha256 }
  end
  private_class_method :binding

  def self.verifier
    Rails.application.message_verifier("playthrough-upload")
  end
  private_class_method :verifier
end
