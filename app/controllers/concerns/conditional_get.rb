module ConditionalGet
  extend ActiveSupport::Concern

  private
    def answer_not_modified(etag:, max_age: 5.minutes)
      expires_in max_age, public: true
      fresh_when(etag: etag, public: true)
    end
end
