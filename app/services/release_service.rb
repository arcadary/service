# Finds a release by the SHA-1 of its game file. Failures are exceptions, so
# callers handle them with rescue_from instead of checking return values.
class ReleaseService
  SHA1 = /\A[0-9a-fA-F]{40}\z/

  def self.find_by(sha1:)
    sha1 = sha1.to_s
    raise Release::InvalidSha1 unless SHA1.match?(sha1)

    Release.includes(:game).find_by(sha1: sha1.downcase) or raise Release::ReleaseNotFound
  end
end
