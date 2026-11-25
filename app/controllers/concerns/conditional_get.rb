# Public caching and conditional GETs for every controller. A controller calls
# it from a before_action lambda that names the ETag's parts:
#
#   before_action -> { answer_not_modified(etag: [ ReleaseDecorator::VERSION, @release, @release.game ]) }
#
# A client whose copy matches gets a 304 and the action never runs.
module ConditionalGet
  extend ActiveSupport::Concern

  private
    def answer_not_modified(etag:, max_age: 5.minutes)
      expires_in max_age, public: true
      fresh_when(etag: etag, public: true)
    end
end
