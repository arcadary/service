---
applyTo: "app/models/**,db/migrate/**"
---

# Models

- Validations and associations only, plus small scopes. Anything that combines records or follows a process goes into a service.
- Every column the API exposes is validated (format, presence, inclusion), so the data behind the OpenAPI document is guaranteed by the model, not only by the controller.
- Values that must not change after creation (`Game#public_id`) are guarded by a validation.
