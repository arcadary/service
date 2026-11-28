class UploadDecorator
  def self.decorate(upload)
    new(upload)
  end

  def initialize(upload)
    @upload = upload
  end

  def as_json(*)
    {
      "upload_id" => @upload.public_id, "type" => @upload.kind, "state" => @upload.state,
      "expires_at" => @upload.expires_at.iso8601, "rejection_reason" => @upload.rejection_reason,
      "files" => @upload.files.map { |file| UploadFileDecorator.decorate(file).as_json }
    }
  end
end
