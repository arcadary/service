class PlaythroughPromotionService
  def self.claim_promotion(staging_id:, release_id:, package_sha256:)
    Rails.logger.silence(Logger::UNKNOWN) do
      stage = PlaythroughStage.find_by(public_id: staging_id)
      raise PlaythroughStage::NotFound, "not_found" unless stage

      PlaythroughLifecycleService.synchronize(stage_id: stage.id) do |current|
        raise PlaythroughStage::Conflict, "stage_conflict" if current.promotion_state == "published"

        PlaythroughLifecycleService.require_open!(stage: current) unless current.promotion_state == "promoting"
        require_binding!(stage: current)
        unless current.release.public_id == release_id && current.package_sha256 == package_sha256
          raise PlaythroughStage::Conflict, "stage_conflict"
        end

        if current.promotion_state == "promoting"
          active = current.promotion_claims.find_by(state: "active")
          require_claim!(stage: current, claim: active)
          next active.token
        end

        claim = current.promotion_claims.create!(token: SecureRandom.hex(48), validation_sha256: validation_sha256(stage: current))
        current.update!(promotion_state: "promoting")
        claim.token
      end
    end
  end

  def self.complete_promotion(claim:)
    finish(claim: claim, outcome: "completed")
  end

  def self.release_promotion(claim:)
    finish(claim: claim, outcome: "released")
  end

  def self.finish(claim:, outcome:)
    Rails.logger.silence(Logger::UNKNOWN) do
      unless claim.is_a?(String) && claim.match?(/\A[0-9a-f]{96}\z/)
        raise PlaythroughStage::Conflict, "stage_conflict"
      end
      record = PlaythroughPromotionClaim.find_by(token: claim)
      raise PlaythroughStage::Conflict, "stage_conflict" unless record

      PlaythroughLifecycleService.synchronize(stage_id: record.playthrough_stage_id) do |stage|
        current = stage.promotion_claims.find(record.id)
        next stage if current.state == outcome
        unless current.state == "active" && stage.promotion_state == "promoting"
          raise PlaythroughStage::Conflict, "stage_conflict"
        end

        require_claim!(stage: stage, claim: current)
        current.update!(state: outcome)
        stage.update!(promotion_state: outcome == "completed" ? "published" : nil)
        PlaythroughLifecycleService.expire(stage: stage)
      end
    end
  end
  private_class_method :finish

  def self.require_claim!(stage:, claim:)
    require_binding!(stage: stage)
    unless claim && claim.validation_sha256 == validation_sha256(stage: stage)
      raise PlaythroughStage::Conflict, "stage_conflict"
    end
  end
  private_class_method :require_claim!

  def self.require_binding!(stage:)
    declaration = stage.declaration
    identity = {
      "staging_id" => stage.public_id, "release_id" => stage.release.public_id,
      "declaration_sha256" => stage.declaration_sha256, "package_sha256" => stage.package_sha256,
      "manifest" => declaration["manifest"], "source_sha1" => declaration["source_sha1"],
      "capture" => declaration["capture"], "verification" => declaration["verification"]
    }
    unless stage.validation_state == "validated" && !stage.validation_error && !stage.expired_at && !stage.reclaimed_at &&
        stage.validation_result&.slice(*identity.keys) == identity && declaration["release_id"] == stage.release.public_id &&
        PlaythroughDeclarationService.fingerprint(declaration: declaration) == stage.declaration_sha256 &&
        PlaythroughDeclarationService.package_sha256(manifest: declaration.fetch("manifest")) == stage.package_sha256 &&
        stage.objects.map { |object| object.attributes.slice("path", "byte_size", "sha256", "content_type") } == declaration["manifest"] &&
        stage.objects.all? { |object| object.received_at && object.blob_id }
      raise PlaythroughStage::Conflict, "stage_conflict"
    end
  end
  private_class_method :require_binding!

  def self.validation_sha256(stage:)
    Digest::SHA256.hexdigest(JSON.generate(stage.validation_result))
  end
  private_class_method :validation_sha256
end
