class ValidationSubmissionService
  PURPOSE = "validation-admission"

  def initialize(configuration:)
    @storage = ValidationStorageService.new(path: configuration.storage_path)
  end

  def admit(sha1:, byte_size:, system:)
    validate_metadata!(sha1: sha1, byte_size: byte_size, system: system)
    checksum = sha1.downcase
    @storage.synchronize(sha1: checksum) do
      reject_known!(sha1: checksum)
      submission = ValidationSubmission.find_or_create_by!(sha1: checksum) { |record| record.assign_attributes(byte_size: byte_size, system: system) }
      raise ValidationSubmission::SubmissionConflict unless submission.byte_size == byte_size && submission.system == system
      if submission.completed_at?
        @storage.confirm!(submission: submission)
        return { status: "received" }
      end

      expires_at = 10.minutes.from_now.change(usec: 0)
      facts = submission.slice(:sha1, :byte_size, :system).merge("nonce" => SecureRandom.hex(16))
      admission = verifier.generate(facts, purpose: PURPOSE, expires_at: expires_at)
      { status: "admitted", admission: admission, expires_at: expires_at.utc.iso8601 }
    end
  end

  def receive(sha1:, admission:, length:, body:)
    raise ValidationSubmission::InvalidMetadata unless sha1.is_a?(String) && ReleaseService::SHA1.match?(sha1)

    checksum = sha1.downcase
    facts = verifier.verified(admission.to_s, purpose: PURPOSE)
    raise ValidationSubmission::InvalidAdmission unless facts.is_a?(Hash) && facts["sha1"] == checksum

    @storage.synchronize(sha1: checksum) do
      submission = ValidationSubmission.find_by(sha1: checksum)
      raise ValidationSubmission::InvalidAdmission unless submission && submission.slice(:sha1, :byte_size, :system) == facts.slice("sha1", "byte_size", "system")
      reject_known!(sha1: checksum)
      raise ValidationSubmission::SizeMismatch unless length == submission.byte_size

      if submission.completed_at?
        @storage.confirm!(submission: submission)
      else
        @storage.receive!(submission: submission, body: body)
      end
      { status: "received" }
    end
  end

  private
    def validate_metadata!(sha1:, byte_size:, system:)
      valid = sha1.is_a?(String) && ReleaseService::SHA1.match?(sha1) && byte_size.is_a?(Integer) && byte_size.positive? && Release::SYSTEMS.include?(system)
      raise ValidationSubmission::InvalidMetadata unless valid
      raise ValidationSubmission::FileTooLarge if byte_size > ValidationSubmission::MAX_BYTES
    end

    def reject_known!(sha1:)
      ReleaseService.resource_for(sha1: sha1)
      raise ValidationSubmission::KnownRelease
    rescue Release::ReleaseNotFound
      nil
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end
end
