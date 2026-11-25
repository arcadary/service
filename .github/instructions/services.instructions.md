---
applyTo: "app/services/**"
---

# Services

The release lookup (`app/controllers/v1/releases_controller.rb`, `app/services/release_service.rb`, `app/decorators/release_decorator.rb`) is the reference example.

A service is where the logic lives: lookups, validation of input, writes, calls to other systems.

- **Location and names.** `app/services/<noun>_service.rb`, as `<Noun>Service` (`ReleaseService`, `ReportService`), next to `<Noun>Decorator`. No namespace: inside a `Service::Release` a bare `Release` would mean the service, not the model. Class methods are named like Active Record where they mean the same (`find_by`, `create`).
- **Keyword arguments** for every input (`ReleaseService.find_by(sha1:)`). This keeps call sites readable and stops Brakeman reading a service call as a raw SQL query.
- **Return the result; raise on failure.** A service returns the record or value the caller asked for, never `nil`, `false` or an error object. Each failure a caller may want to handle is its own exception class, defined in the service (`ReleaseService::ReleaseNotFound < StandardError`). Name it for what went wrong, not for the HTTP status.
- **Validate at the edge.** The service checks its input's format before it touches the database (a malformed checksum raises `InvalidSha1`, it does not query).
- **No HTTP in services.** No `params`, `request`, `render` or status codes. A service is callable from a controller, a job, the console or a spec alike.
- **Short transactions.** SQLite has one writer at a time: keep writes in a short `transaction`, and move slow work (outbound requests, large imports) into a Solid Queue job that calls the service.
- **Eager-load what the decorator needs** (`includes(:game)`), so rendering does not run extra queries.
