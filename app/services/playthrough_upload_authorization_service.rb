class PlaythroughUploadAuthorizationService
  LIFETIME = 900

  def self.issue(stage:)
    expires_at = (Time.current + LIFETIME).iso8601(9)
    payload = bound_identity(stage: stage).merge("expires_at" => expires_at, "nonce" => SecureRandom.hex(16))
    { capability: verifier.generate(payload, purpose: "playthrough-upload"), expires_at: expires_at }
  end

  def self.authorize!(capability:, staging_id:, object_id:)
    raise PlaythroughStage::UploadNotAuthorized unless capability.is_a?(String) && capability.bytesize <= 4096

    payload = verifier.verified(capability, purpose: "playthrough-upload")
    unless payload.is_a?(Hash) && payload["expires_at"].is_a?(String) && Time.current < Time.iso8601(payload["expires_at"])
      raise PlaythroughStage::UploadNotAuthorized
    end

    stage = PlaythroughStage.includes(:release).find_by(public_id: staging_id)
    unless stage && payload.slice(*bound_identity(stage: stage).keys) == bound_identity(stage: stage) && stage.objects.exists?(public_id: object_id)
      raise PlaythroughStage::UploadNotAuthorized
    end
    stage
  end

  def self.bound_identity(stage:)
    { "staging_id" => stage.public_id, "release_id" => stage.release.public_id,
      "package_sha256" => stage.package_sha256, "declaration_sha256" => stage.declaration_sha256 }
  end
  private_class_method :bound_identity

  def self.verifier
    Rails.application.message_verifier("playthrough-upload")
  end
  private_class_method :verifier
end
