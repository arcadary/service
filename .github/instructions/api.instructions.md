---
applyTo: "app/controllers/v*/**,config/routes.rb,swagger/**"
---

# API design

- Routes are versioned (`/v1/...`). JSON routes end in `.json`; content-addressed screenshot delivery ends in `.png`. A change to a field's meaning or type is a new version; adding an optional field is not.
- Public read endpoints are `GET`, anonymous and cacheable: the same URL returns the same bytes for every caller. Authenticated private playthrough metadata and future HLS delivery use the shared admin Basic guard, `no-store` and log suppression across their complete subtree; no private footage or metadata enters anonymous responses. Staging exposes no bytes or playback. Catalog and screenshot licences grant no video rights.
- **One entry point per question.** Clients ask `GET /v1/lookup/{sha1}.json` what a file is and follow the `301` to its resource (`/v1/releases/{sha1}.json`, later other kinds). Each kind of resource has its own URL and controller; the lookup only decides where to send the client. A redirect carries a `max-age` (a day), never an unbounded 301, so a wrong answer can be corrected; unknown checksums answer `404` with `no-store`, so a file added later shows up at once.
- Errors are `{ "error": "<snake_case_code>" }` with a fitting status (`400` malformed input, `404` unknown, `422` a write that fails validation). The code is stable; clients match on it, not on a message.
