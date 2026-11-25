class ReleaseService
  SHA1 = /\A[0-9a-fA-F]{40}\z/

  def self.find_by(sha1:)
    Release.includes(:game).find_by(sha1: normalize(sha1)) or raise Release::ReleaseNotFound
  end

  def self.exists?(sha1:)
    Release.exists?(sha1: normalize(sha1))
  end

  def self.normalize(sha1)
    sha1 = sha1.to_s
    raise Release::InvalidSha1 unless SHA1.match?(sha1)

    sha1.downcase
  end
  private_class_method :normalize
end
