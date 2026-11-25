---
applyTo: "app/controllers/v*/**,config/routes.rb,swagger/**"
---

# API design

- Routes are versioned (`/v1/...`) and end in `.json`. A change to a field's meaning or type is a new version; adding an optional field is not.
- Read endpoints are `GET`, anonymous and cacheable: the same URL returns the same bytes for every caller.
- Errors are `{ "error": "<snake_case_code>" }` with a fitting status (`400` malformed input, `404` unknown, `422` a write that fails validation). The code is stable; clients match on it, not on a message.
