module ConditionalGet
  extend ActiveSupport::Concern

  private
    def answer_not_modified(record:, version:, max_age: 5.minutes)
      expires_in max_age, public: true
      fresh_when(etag: [ version, record ], last_modified: record.updated_at, public: true)
    end
end
