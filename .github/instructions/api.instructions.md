---
applyTo: "app/controllers/v*/**,config/routes.rb,swagger/**"
---

# API design

- Routes are versioned (`/v1/...`). JSON routes end in `.json`; content-addressed screenshot delivery ends in `.png`. A change to a field's meaning or type is a new version; adding an optional field is not.
- Read endpoints are `GET`, anonymous and cacheable: the same URL returns the same bytes for every caller.
- This public-read rule does not cover writes. Validation admission/upload are anonymous, cookie-free and always `no-store`; reviewer routes are authenticated and always `no-store`. Exclude both validation path families from shared caches.
- **One entry point per question.** Clients ask `GET /v1/lookup/{sha1}.json` what a file is and follow the `301` to its resource (`/v1/releases/{sha1}.json`, later other kinds). Each kind of resource has its own URL and controller; the lookup only decides where to send the client. A redirect carries a `max-age` (a day), never an unbounded 301, so a wrong answer can be corrected; unknown checksums answer `404` with `no-store`, so a file added later shows up at once.
- Errors are `{ "error": "<snake_case_code>" }` with a fitting status (`400` malformed input, `404` unknown, `422` a write that fails validation). The code is stable; clients match on it, not on a message.
- Receipt errors contain only the code, never input echo: `400 invalid_metadata`, `403 invalid_admission`, `408 upload_timeout`, `409 known_release/submission_conflict`, `411 length_required`, `413 metadata_too_large/file_too_large`, `415 unsupported_media_type`, `422 size_mismatch/checksum_mismatch`, `503 unavailable`. Availability is first; preserve the ordered Rack gates in README and #26. Accept admissions only in `X-Validation-Admission`, never URLs/cookies. Exact request/response shapes and headers belong in rswag, including the Rack-handled endpoints.
