---
applyTo: "app/decorators/**"
---

# Decorators

The release lookup (`app/controllers/v1/releases_controller.rb`, `app/services/release_service.rb`, `app/decorators/release_decorator.rb`) is the reference example.

A decorator turns a record into the public JSON shape. It is the only place that shape is defined.

- `app/decorators/<model>_decorator.rb`, a plain Ruby class with `.decorate(record)` and `#as_json`. No gem.
- It exposes only the fields the API documents, by name (`slice(:sha1, :system, ...)`), never `attributes` or `to_json` of the whole record. Database IDs and timestamps stay out; games are identified by `public_id`.
- No queries and no logic beyond formatting. What it needs is loaded by the service.
- **`VERSION` and `.version`.** Each decorator has a `VERSION` integer; bump it in the same change as any change to its own output (a field added, renamed or formatted differently). `.version` is what goes into the ETag: its own `VERSION` plus the `.version` of every decorator it embeds (`ReleaseDecorator.version` is `[ VERSION, *GameDecorator.version ]`), so a change to the game's shape reaches every response that contains a game.
- **One decorator per model.** A record that appears inside another response is rendered by its own decorator (`game: GameDecorator.decorate(@release.game).as_json`), never by repeating its fields.
