require "digest/sha1"
require "timeout"

class ValidationStorageService
  CHUNK_BYTES = 64 * 1024
  READ_SECONDS = 120

  def initialize(path:)
    @path = path
  end

  def synchronize(sha1:)
    File.open(@path.join("#{sha1}.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  rescue SystemCallError, IOError
    raise ValidationSubmission::Unavailable
  end

  def confirm!(submission:)
    file = @path.join("#{submission.sha1}.data")
    stat = file.lstat
    raise ValidationSubmission::Unavailable unless stat.file? && stat.size == submission.byte_size && stat.owned? && stat.mode & 0o077 == 0 && file.readable?
  rescue SystemCallError, IOError
    raise ValidationSubmission::Unavailable
  end

  def receive!(submission:, body:)
    staging = @path.join("#{submission.sha1}.stage")
    File.unlink(staging) if staging.exist? || staging.symlink?
    File.open(staging, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
      file.binmode
      verify_body!(submission: submission, body: body, file: file)
      file.flush
      file.fsync
    end
    File.rename(staging, @path.join("#{submission.sha1}.data"))
    File.open(@path, File::RDONLY) { |directory| directory.fsync }
    submission.update!(completed_at: Time.current)
  ensure
    File.unlink(staging) if staging && (staging.exist? || staging.symlink?)
  end

  private
    def verify_body!(submission:, body:, file:)
      count = 0
      digest = Digest::SHA1.new
      Timeout.timeout(READ_SECONDS, ValidationSubmission::UploadTimeout) do
        loop do
          chunk = body.read([ CHUNK_BYTES, ValidationSubmission::MAX_BYTES - count + 1 ].min)
          break if chunk.nil? || chunk.empty?

          count += chunk.bytesize
          raise ValidationSubmission::FileTooLarge if count > ValidationSubmission::MAX_BYTES
          digest.update(chunk)
          file.write(chunk)
        end
      end
      raise ValidationSubmission::SizeMismatch unless count == submission.byte_size
      raise ValidationSubmission::ChecksumMismatch unless digest.hexdigest == submission.sha1
    end
end
