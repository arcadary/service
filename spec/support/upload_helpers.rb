module UploadHelpers
  def content_digest(bytes)
    "sha-256=:#{Base64.strict_encode64(Digest::SHA256.digest(bytes))}:"
  end

  def receive_file(upload:, name:, bytes:, content_type:)
    UploadService.receive(upload_id: upload.public_id, name: name, io: StringIO.new(bytes), content_type: content_type,
      content_length: bytes.bytesize, digest: content_digest(bytes))
  end

  def confirmed_upload(kind:, files:)
    upload = UploadService.create(kind: kind)
    files.each { |name, (bytes, content_type)| receive_file(upload: upload, name: name, bytes: bytes, content_type: content_type) }
    UploadService.confirm(upload_id: upload.public_id)
    UploadCheckJob.perform_now(upload.id)
    upload.reload
  end

  def stub_admin_credentials
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_USERNAME").and_return("synthetic-admin")
    allow(ENV).to receive(:[]).with("VALIDATION_REVIEWER_PASSWORD").and_return("synthetic-password")
  end

  def admin_authorization
    ActionController::HttpAuthentication::Basic.encode_credentials("synthetic-admin", "synthetic-password")
  end

  def put_upload_file(path, bytes:, content_type:, authorization: admin_authorization, digest: content_digest(bytes))
    put path, params: bytes, headers: { "Authorization" => authorization, "CONTENT_TYPE" => content_type, "Content-Digest" => digest }
  end
end
