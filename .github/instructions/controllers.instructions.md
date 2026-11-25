---
applyTo: "app/controllers/**"
---

# Controllers

The release lookup (`app/controllers/v1/releases_controller.rb`, `app/services/service/release.rb`, `app/decorators/release_decorator.rb`) is the reference example.

A controller translates HTTP into a service call and a rendered result. It holds no business logic.

- **Actions are one or two lines.** The action renders; everything before that happens in before actions.

  ```ruby
  module V1
    class ReleasesController < ActionController::API
      rescue_from Service::Release::InvalidSha1, with: :invalid_sha1
      rescue_from Service::Release::ReleaseNotFound, with: :release_not_found

      before_action :set_release
      before_action :answer_not_modified

      def show
        render json: ReleaseDecorator.decorate(@release)
      end
    end
  end
  ```

- **Before actions do the setup.** Loading the record (`set_release`), authorisation, and conditional requests: a before action that calls `fresh_when` answers `304` and stops the chain before the action runs. Name them for what they do (`set_*`, `require_*`, `answer_*`).
- **Errors are `rescue_from`, not `if`.** A controller never checks a service's return value for failure. Each exception a service can raise maps to one handler, and each handler renders one documented error response. Unexpected exceptions are not rescued; they become a `500`.
- **JSON API controllers inherit `ActionController::API`**, live under `V1::` (or the next version), and set no cookie or session. HTML pages (the homepage, reviewer pages) inherit `ApplicationController`.
- **Strong parameters, scalar values.** Read a parameter once, as the type the service expects (`params[:sha1].to_s`), and pass it as a keyword argument. Never pass `params` or a hash of them into a service.
- **Caching is explicit.** A public read sets `expires_in ... public: true` and an ETag taken from the rendered body. Errors and anything personal send `Cache-Control: no-store`.
