class StorageConfigurationService
  def self.require_storage!
    config = Rails.application.config
    raise Upload::StorageDisabled unless config.active_storage.service && config.x.media_service && media_base_url.present?
  end

  def self.media_base_url
    Rails.application.config.x.media_base_url
  end

  def self.media_service_name
    Rails.application.config.x.media_service
  end

  def self.private_service
    ActiveStorage::Blob.service
  end

  def self.uploads_root
    Pathname(Rails.application.config.x.uploads_root)
  end
end
