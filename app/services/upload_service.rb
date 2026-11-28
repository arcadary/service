class UploadService
  DIGEST = %r{(?:\A|,)\s*sha-256=:([A-Za-z0-9+/]{43}=):\s*(?:,|\z)}
  KEPT = %w[requested receiving checking confirmed].freeze

  def self.create(kind:)
    raise Upload::InvalidInput unless Upload::LIMITS.key?(kind)

    StorageConfigurationService.require_storage!
    Upload.create!(kind: kind, state: "requested", expires_at: Upload::LIFETIME.from_now)
  end

  def self.find_by(upload_id:)
    upload = Upload.find_by(public_id: upload_id.to_s)
    raise Upload::NotFound unless upload
    raise Upload::Expired if upload.expired?

    upload
  end

  def self.receive(upload_id:, name:, io:, content_type:, content_length:, digest:)
    upload = find_by(upload_id: upload_id)
    raise Upload::Conflict unless Upload::RECEIVING.include?(upload.state)

    sha256 = sha256(digest: digest)
    unless UploadFile.valid_name?(name) && upload.limits.fetch(:content_types).include?(content_type) &&
        content_length.is_a?(Integer) && content_length.positive?
      raise Upload::Rejected
    end

    require_room!(upload: upload, size: content_length) unless upload.files.exists?(name: name)
    bytes = read(io: io, limit: upload.limits.fetch(:file_bytes))
    unless bytes.bytesize == content_length && Digest::SHA256.hexdigest(bytes) == sha256 &&
        handler(upload: upload).file_type?(content_type: content_type, bytes: bytes)
      raise Upload::Rejected
    end

    file = record(upload: upload, name: name, byte_size: content_length, sha256: sha256, content_type: content_type)
    begin
      UploadStorageService.write(upload: upload, name: name, bytes: bytes)
    rescue Upload::StorageUnavailable
      file.destroy if file.previously_new_record?
      raise
    end
    file
  end

  def self.confirm(upload_id:)
    upload = find_by(upload_id: upload_id)
    return upload if %w[checking confirmed rejected].include?(upload.state)
    raise Upload::Conflict unless Upload.where(id: upload.id, state: "receiving").update_all(state: "checking", updated_at: Time.current) == 1

    UploadCheckJob.perform_later(upload.id)
    upload.reload
  end

  def self.check(upload:)
    upload.update!(state: "confirmed", media: handler(upload: upload).check(upload: upload))
  rescue Upload::Rejected => error
    UploadStorageService.delete(public_id: upload.public_id)
    upload.update!(state: "rejected", rejection_reason: error.message)
  rescue StandardError
    upload.update!(state: "receiving")
    raise
  end

  def self.use(upload_id:, kind:)
    upload = find_by(upload_id: upload_id)
    unless upload.kind == kind && Upload.where(id: upload.id, state: "confirmed").update_all(state: "used", updated_at: Time.current) == 1
      raise Upload::Conflict
    end

    begin
      result = yield upload
    rescue StandardError
      Upload.where(id: upload.id, state: "used").update_all(state: "confirmed")
      raise
    end
    UploadStorageService.delete(public_id: upload.public_id)
    result
  end

  def self.cleanup
    orphans = UploadStorageService.directories
    Upload.where(expires_at: ..Time.current).find_each do |upload|
      handler(upload: upload).expire(upload: upload)
      UploadStorageService.delete(public_id: upload.public_id)
      upload.destroy!
    end
    (orphans - Upload.pluck(:public_id)).each { |public_id| UploadStorageService.delete(public_id: public_id) }
  end

  def self.handler(upload:)
    { "screenshot" => ScreenshotService, "video" => PlaythroughService }.fetch(upload.kind)
  end
  private_class_method :handler

  def self.sha256(digest:)
    encoded = DIGEST.match(digest.to_s)&.[](1)
    raise Upload::Rejected unless encoded

    Base64.strict_decode64(encoded).unpack1("H*")
  rescue ArgumentError
    raise Upload::Rejected
  end
  private_class_method :sha256

  def self.require_room!(upload:, size:)
    limits = upload.limits
    raise Upload::TooLarge if size > limits.fetch(:file_bytes) || upload.files.count >= limits.fetch(:files) ||
      upload.files.sum(:byte_size) + size > limits.fetch(:upload_bytes)

    stored = UploadFile.joins(:upload).where(uploads: { state: KEPT }).sum(:byte_size)
    raise Upload::Full if stored + size > Upload::QUOTA_BYTES
  end
  private_class_method :require_room!

  def self.read(io:, limit:)
    bytes = io.read(limit + 1).to_s.b
    raise Upload::TooLarge if bytes.bytesize > limit

    bytes
  rescue IOError, EOFError, SystemCallError
    raise Upload::InterruptedTransfer
  end
  private_class_method :read

  def self.record(upload:, name:, byte_size:, sha256:, content_type:)
    file = Upload.transaction do
      raise Upload::Conflict unless Upload.where(id: upload.id, state: Upload::RECEIVING).update_all(state: "receiving", updated_at: Time.current) == 1

      upload.files.create_or_find_by!(name: name) do |created|
        created.assign_attributes(byte_size: byte_size, sha256: sha256, content_type: content_type)
      end
    end
    raise Upload::Conflict unless file.sha256 == sha256 && file.content_type == content_type

    file
  end
  private_class_method :record
end
