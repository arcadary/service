class PlaythroughStagingService
  def self.create(declaration:, verifier:)
    declaration = PlaythroughDeclarationService.normalize(declaration: declaration, verifier: verifier)
    fingerprint = PlaythroughDeclarationService.fingerprint(declaration: declaration)
    retry_key = declaration.fetch("retry_key")
    stage = PlaythroughStage.transaction do
      existing = PlaythroughStage.find_by(retry_key: retry_key)
      next replay(stage: existing, fingerprint: fingerprint) if existing

      release = Release.find_by(public_id: declaration.fetch("release_id"))
      raise Release::ReleaseNotFound unless release

      require_membership!(release: release, declaration: declaration)
      stage = PlaythroughStage.create!(release: release, retry_key: retry_key, declaration: declaration,
        declared_at: Time.current,
        declaration_sha256: fingerprint, package_sha256: PlaythroughDeclarationService.package_sha256(manifest: declaration.fetch("manifest")))
      declaration.fetch("manifest").each { |entry| stage.objects.create!(entry) }
      stage
    end
    stage = find_by(staging_id: stage.public_id)
    PlaythroughLifecycleService.require_open!(stage: stage)
    stage
  rescue ActiveRecord::RecordNotUnique
    stage = replay(stage: PlaythroughStage.find_by!(retry_key: retry_key), fingerprint: fingerprint)
    stage = find_by(staging_id: stage.public_id)
    PlaythroughLifecycleService.require_open!(stage: stage)
    stage
  end

  def self.find_by(staging_id:)
    PlaythroughStage.uncached do
      stage = PlaythroughStage.find_by(public_id: staging_id)
      raise PlaythroughStage::NotFound, "not_found" unless stage

      PlaythroughLifecycleService.synchronize(stage_id: stage.id) { |current| current }
      PlaythroughStage.includes(:objects).find(stage.id)
    end
  end

  def self.replay(stage:, fingerprint:)
    raise PlaythroughStage::Conflict unless stage.declaration_sha256 == fingerprint

    PlaythroughLifecycleService.expire(stage: stage)

    stage
  end
  private_class_method :replay

  def self.require_membership!(release:, declaration:)
    source = declaration.fetch("source_sha1")
    verification = declaration["verification"]
    if release.media_files.exists?(sha1: source)
      raise PlaythroughStage::TargetMismatch if verification
    elsif !verification || !release.media_files.exists?(sha1: verification.fetch("payload_sha1"))
      raise PlaythroughStage::TargetMismatch
    end
  end
  private_class_method :require_membership!
end
