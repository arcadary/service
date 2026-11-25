---
applyTo: "spec/**"
---

# Specs

- **Request specs with rswag** for every endpoint, in `spec/requests`: each documented status, its JSON schema with `additionalProperties: false`, and the cache headers. Run `mise run openapi` and commit `swagger/v1/swagger.yaml`.
- **Service specs** in `spec/services/service`: the result for good input and each exception for bad input.
- **Decorator specs** in `spec/decorators`: the exact JSON shape.
- **Model specs** in `spec/models`: validations and associations.
- No network in specs; a service that calls out gets a fake.
