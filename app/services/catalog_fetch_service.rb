require "digest"
require "fileutils"
require "json"
require "net/http"
require "uri"

class CatalogFetchService
  class FetchFailed < StandardError; end

  MANIFEST = JSON.parse(File.read(Rails.root.join("data/catalog/dats.json"))).freeze

  def self.fetch(folder:, files: MANIFEST.fetch("systems").values.map { |entry| entry.fetch("file") }, downloader: method(:download))
    allowed = MANIFEST.fetch("systems").values.index_by { |entry| entry.fetch("file") }
    raise FetchFailed, "refusing file outside pinned allowlist" unless files.all? { |file| allowed.key?(file) }

    FileUtils.mkdir_p(folder)
    files.each do |file|
      url = "https://raw.githubusercontent.com/#{MANIFEST.fetch('repository')}/#{MANIFEST.fetch('commit')}/#{MANIFEST.fetch('path')}/#{URI::DEFAULT_PARSER.escape(file)}"
      bytes = downloader.call(url)
      raise FetchFailed, "SHA-256 mismatch for #{file}" unless Digest::SHA256.hexdigest(bytes) == allowed.fetch(file).fetch("sha256")

      destination = Pathname.new(folder).join(file)
      temporary = Pathname.new("#{destination}.part")
      begin
        File.binwrite(temporary, bytes)
        File.rename(temporary, destination)
      ensure
        FileUtils.rm_f(temporary)
      end
    end
    files.size
  end

  def self.download(url)
    response = Net::HTTP.get_response(URI(url))
    response.value
    response.body
  end
  private_class_method :download
end
