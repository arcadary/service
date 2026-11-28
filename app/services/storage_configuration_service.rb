class StorageConfigurationService
  def self.require_storage!
    raise Upload::StorageDisabled unless Rails.application.config.active_storage.service && media_base_url.present?
  end

  def self.media_base_url
    Rails.application.config.x.media_base_url
  end

  def self.media_service
    ActiveStorage::Blob.service
  end

  def self.uploads_root
    Pathname(Rails.application.config.x.uploads_root)
  end
end
