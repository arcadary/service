class UploadStorageService
  def self.write(upload:, name:, bytes:)
    path = path(upload: upload, name: name)
    path.dirname.mkpath
    File.atomic_write(path) { |file| file.write(bytes) }
  rescue SystemCallError
    raise Upload::StorageUnavailable
  end

  def self.read(upload:, name:)
    path(upload: upload, name: name).binread
  rescue SystemCallError
    raise Upload::StorageUnavailable
  end

  def self.path(upload:, name:)
    raise Upload::Rejected unless UploadFile.valid_name?(name)

    StorageConfigurationService.uploads_root.join(upload.public_id, name)
  end

  def self.delete(public_id:)
    FileUtils.rm_rf(StorageConfigurationService.uploads_root.join(public_id))
  end

  def self.directories
    root = StorageConfigurationService.uploads_root
    root.exist? ? root.children.select(&:directory?).map { |child| child.basename.to_s } : []
  end
end
