# Code guidelines

How code in this service is shaped. `AGENTS.md` holds the rules (privacy, secrets, what the service is); this page holds the patterns. When a change does not fit them, say why in the pull request rather than working around them quietly.

The release lookup (`app/controllers/v1/releases_controller.rb`, `app/services/service/release.rb`, `app/decorators/release_decorator.rb`) is the reference example.

## Controllers

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

## Services

A service is where the logic lives: lookups, validation of input, writes, calls to other systems.

- **Location and names.** `app/services/service/<noun>.rb`, as `Service::<Noun>`. One module per domain noun (`Service::Release`, `Service::Report`), with class methods named like ActiveRecord where they mean the same (`find_by`, `create`).
- **Keyword arguments** for every input (`Service::Release.find_by(sha1:)`). This keeps call sites readable and stops Brakeman reading a service call as a raw SQL query.
- **Return the result; raise on failure.** A service returns the record or value the caller asked for, never `nil`, `false` or an error object. Each failure a caller may want to handle is its own exception class, defined in the service (`Service::Release::ReleaseNotFound < StandardError`). Name it for what went wrong, not for the HTTP status.
- **Validate at the edge.** The service checks its input's format before it touches the database (a malformed checksum raises `InvalidSha1`, it does not query).
- **No HTTP in services.** No `params`, `request`, `render` or status codes. A service is callable from a controller, a job, the console or a spec alike.
- **Short transactions.** SQLite has one writer at a time: keep writes in a short `transaction`, and move slow work (outbound requests, large imports) into a Solid Queue job that calls the service.
- **Eager-load what the decorator needs** (`includes(:game)`), so rendering does not run extra queries.

## Decorators

A decorator turns a record into the public JSON shape. It is the only place that shape is defined.

- `app/decorators/<model>_decorator.rb`, a plain Ruby class with `.decorate(record)` and `#as_json`. No gem.
- It exposes only the fields the API documents, by name (`slice(:sha1, :system, ...)`), never `attributes` or `to_json` of the whole record. Database IDs and timestamps stay out; games are identified by `public_id`.
- No queries and no logic beyond formatting. What it needs is loaded by the service.

## Models

- Validations and associations only, plus small scopes. Anything that combines records or follows a process goes into a service.
- Every column the API exposes is validated (format, presence, inclusion), so the data behind the OpenAPI document is guaranteed by the model, not only by the controller.
- Values that must not change after creation (`Game#public_id`) are guarded by a validation.

## API design

- Routes are versioned (`/v1/...`) and end in `.json`. A change to a field's meaning or type is a new version; adding an optional field is not.
- Read endpoints are `GET`, anonymous and cacheable: the same URL returns the same bytes for every caller.
- Errors are `{ "error": "<snake_case_code>" }` with a fitting status (`400` malformed input, `404` unknown, `422` a write that fails validation). The code is stable; clients match on it, not on a message.

## Specs

- **Request specs with rswag** for every endpoint, in `spec/requests`: each documented status, its JSON schema with `additionalProperties: false`, and the cache headers. Run `mise run openapi` and commit `swagger/v1/swagger.yaml`.
- **Service specs** in `spec/services/service`: the result for good input and each exception for bad input.
- **Decorator specs** in `spec/decorators`: the exact JSON shape.
- **Model specs** in `spec/models`: validations and associations.
- No network in specs; a service that calls out gets a fake.

## Logging and privacy

- Never log a client IP address, and never log a checksum together with anything that could tie it to a household. `config/initializers/filter_parameter_logging.rb` filters the checksum parameter; extend it for every new identifying parameter.
- Telemetry is internal and anonymised (see `AGENTS.md`).
