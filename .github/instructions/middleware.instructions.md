---
applyTo: "lib/middleware/**"
---

# Middleware

- Keep HTTP concerns here and credential comparison in services. Middleware must not parse request bodies before authentication.
- Private request protection runs before `Rails::Rack::Logger`; retain log suppression and `Cache-Control: no-store` for failures as well as successes.
- Register private path matchers explicitly and cover each consumer with request specs. Match the entire private route subtree, including errors and repeated slashes; public reads and capture bearer authentication remain separate.
