---
applyTo: "app/models/**,db/migrate/**"
---

# Models

- Validations and associations only, plus small scopes. Anything that combines records or follows a process goes into a service.
- Every column the API exposes is validated (format, presence, inclusion), so the data behind the OpenAPI document is guaranteed by the model, not only by the controller.
- Values that must not change after creation (`Game#public_id`) are guarded by a validation.
- **`updated_at` must move.** ETags are built from `updated_at`, so every change to an exposed field goes through Active Record (`update!`, `save!`) or, for bulk writes (`upsert_all`, imports), sets `updated_at` explicitly. Never change exposed data with `update_columns`, `update_all` or raw SQL.
- **Exceptions live in the model.** The errors services raise about a record are collected in its model (`Release::ReleaseNotFound`, `Release::InvalidSha1`), next to its validations. Only an exception specific to one service stays in that service.
