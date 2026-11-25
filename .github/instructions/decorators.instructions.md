---
applyTo: "app/decorators/**"
---

# Decorators

The release lookup (`app/controllers/v1/releases_controller.rb`, `app/services/release_service.rb`, `app/decorators/release_decorator.rb`) is the reference example.

A decorator turns a record into the public JSON shape. It is the only place that shape is defined.

- `app/decorators/<model>_decorator.rb`, a plain Ruby class with `.decorate(record)` and `#as_json`. No gem.
- It exposes only the fields the API documents, by name (`slice(:sha1, :system, ...)`), never `attributes` or `to_json` of the whole record. Database IDs and timestamps stay out; games are identified by `public_id`.
- No queries and no logic beyond formatting. What it needs is loaded by the service.
- **`VERSION`.** Each decorator has a `VERSION` integer that is part of the ETag. Bump it in the same change as any change to its output (a field added, renamed or formatted differently), or clients keep getting `304` for the old shape.
