---
applyTo: "spec/**"
---

# Specs

**Test real cases, not theoretical ones.** A spec earns its place when it covers something a real client, a real data change or a real bug can do: the documented responses, the behaviour the launcher relies on, a regression that happened. It does not cover inputs no caller sends, every permutation of a format, framework or gem behaviour, configuration that Rails already guarantees, or a code path kept only for completeness. One representative example per behaviour is enough; a list of near-identical cases is not. A spec that is slow, starts processes or depends on timing needs a real case behind it, and specs never test comments or prose.

- **Request specs with rswag** for every endpoint, in `spec/requests`: each documented status, its JSON schema with `additionalProperties: false`, and the cache headers. Run `mise run openapi` and commit `swagger/v1/swagger.yaml`.
- **Service specs** in `spec/services/service`: the result for good input and each exception for bad input.
- **Decorator specs** in `spec/decorators`: the exact JSON shape.
- **Model specs** in `spec/models`: validations and associations.
- No network in specs; a service that calls out gets a fake.
