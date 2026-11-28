class CatalogMutation < ApplicationRecord
  validates :idempotency_key, :fingerprint, :operation, :admin_name, :reason, presence: true
end
