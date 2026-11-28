require "json"

class ValidationReceipts
  class UnsupportedMediaType < StandardError; end
  class MetadataTooLarge < StandardError; end
  class LengthRequired < StandardError; end

  ERRORS = {
    "InvalidMetadata" => [ 400, "invalid_metadata" ],
    "InvalidAdmission" => [ 403, "invalid_admission" ],
    "SubmissionConflict" => [ 409, "submission_conflict" ],
    "KnownRelease" => [ 409, "known_release" ],
    "FileTooLarge" => [ 413, "file_too_large" ],
    "SizeMismatch" => [ 422, "size_mismatch" ],
    "ChecksumMismatch" => [ 422, "checksum_mismatch" ],
    "UploadTimeout" => [ 408, "upload_timeout" ],
    "Unavailable" => [ 503, "unavailable" ],
    "UnsupportedMediaType" => [ 415, "unsupported_media_type" ],
    "MetadataTooLarge" => [ 413, "metadata_too_large" ],
    "LengthRequired" => [ 411, "length_required" ]
  }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    path = env.fetch("PATH_INFO", "").gsub(%r{/+}, "/")
    return @app.call(env) unless %r{\A/v1/validations(?:/|\.|\z)}.match?(path)

    Rails.logger.silence do
      Rails.application.executor.wrap { receipt(env: env, path: path) }
    end
  end

  private
    def receipt(env:, path:)
      configuration = ValidationConfigurationService.new.check!
      service = ValidationSubmissionService.new(configuration: configuration)
      if env["REQUEST_METHOD"] == "POST" && path == "/v1/validations.json"
        require_media!(env: env, type: "application/json")
        metadata = read_metadata(env: env)
        result = service.admit(sha1: metadata["sha1"], byte_size: metadata["byte_size"], system: metadata["system"])
        answer(status: result[:status] == "admitted" ? 201 : 200, body: result)
      elsif env["REQUEST_METHOD"] == "PUT" && (match = %r{\A/v1/validations/([^/]+)/file\.json\z}.match(path))
        require_media!(env: env, type: "application/octet-stream")
        length = upload_length(env: env)
        result = service.receive(sha1: match[1], admission: env["HTTP_X_VALIDATION_ADMISSION"], length: length, body: env["rack.input"])
        answer(status: 200, body: result)
      else
        raise ValidationSubmission::InvalidMetadata
      end
    rescue ValidationSubmission::InvalidMetadata, ValidationSubmission::InvalidAdmission,
      ValidationSubmission::SubmissionConflict, ValidationSubmission::KnownRelease, ValidationSubmission::FileTooLarge,
      ValidationSubmission::SizeMismatch, ValidationSubmission::ChecksumMismatch, ValidationSubmission::UploadTimeout,
      ValidationSubmission::Unavailable, UnsupportedMediaType, MetadataTooLarge, LengthRequired => error
      status, code = ERRORS.fetch(error.class.name.demodulize)
      answer(status: status, body: { error: code })
    rescue ActiveRecord::ActiveRecordError, SystemCallError, IOError
      answer(status: 503, body: { error: "unavailable" })
    end

    def require_media!(env:, type:)
      encoding = env["HTTP_CONTENT_ENCODING"]
      raise UnsupportedMediaType unless (encoding.nil? || encoding == "identity") && env["CONTENT_TYPE"].to_s.split(";", 2).first.to_s.strip.downcase == type
    end

    def read_metadata(env:)
      length = env["CONTENT_LENGTH"]
      raise MetadataTooLarge if length.to_s.match?(/\A[0-9]+\z/) && length.to_i > 1024

      json = +"".b
      while json.bytesize < 1025
        chunk = env.fetch("rack.input").read(1025 - json.bytesize)
        break if chunk.nil? || chunk.empty?

        json << chunk
      end
      raise MetadataTooLarge if json.bytesize > 1024
      metadata = JSON.parse(json)
      raise ValidationSubmission::InvalidMetadata unless metadata.is_a?(Hash) && metadata.keys.sort == %w[byte_size sha1 system]

      metadata
    rescue JSON::ParserError, EncodingError
      raise ValidationSubmission::InvalidMetadata
    end

    def upload_length(env:)
      value = env["CONTENT_LENGTH"]
      raise LengthRequired if value.nil?
      raise ValidationSubmission::InvalidMetadata unless value.is_a?(String) && /\A[0-9]+\z/.match?(value)

      length = value.to_i
      raise ValidationSubmission::FileTooLarge if length > ValidationSubmission::MAX_BYTES

      length
    end

    def answer(status:, body:)
      json = JSON.generate(body)
      [ status, { "content-type" => "application/json; charset=utf-8", "content-length" => json.bytesize.to_s, "cache-control" => "no-store" }, [ json ] ]
    end
end
